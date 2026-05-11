# frozen_string_literal: true

require 'bigdecimal'

module CoindcxBot
  module Exchanges
    module Binance
      # In-memory L2 book reconstructed from a REST snapshot plus Binance Futures
      # diff updates. Prices and quantities are BigDecimal for exact arithmetic.
      # Sequence validation is intentionally NOT this object's job — see
      # SequenceValidator and ResyncManager.
      #
      # Optional +on_delta+ / +on_reset+ callbacks fire **outside** the book mutex
      # after mutations complete (safe to call back into +top_bids+ / +mid+, etc.).
      class LocalBook
        attr_reader :last_update_id

        def initialize
          @bids = {}
          @asks = {}
          @last_update_id = nil
          @mutex = Mutex.new
          @listener_mutex = Mutex.new
          @delta_listeners = []
          @reset_listeners = []
        end

        def on_delta(&block)
          @listener_mutex.synchronize { @delta_listeners << block }
          self
        end

        def on_reset(&block)
          @listener_mutex.synchronize { @reset_listeners << block }
          self
        end

        # Replace the full book from a REST snapshot.
        # @param last_update_id [Integer]
        # @param bids [Array<[BigDecimal, BigDecimal]>]
        # @param asks [Array<[BigDecimal, BigDecimal]>]
        def replace!(last_update_id:, bids:, asks:)
          @mutex.synchronize do
            @last_update_id = Integer(last_update_id)
            @bids = build_side(bids)
            @asks = build_side(asks)
          end
          fire_resets
          self
        end

        # Apply a Binance futures diffDepth update.
        # @param final_u [Integer] event final update id (becomes new last_update_id)
        # @param bids [Array<[price, qty]>] qty == 0 deletes the level
        # @param asks [Array<[price, qty]>] qty == 0 deletes the level
        # @param event_time [Integer, nil] Binance event time +E+ (milliseconds); used in delta payloads
        def apply_diff!(final_u:, bids:, asks:, event_time: nil)
          ts_ms = normalize_event_time_ms(event_time)
          deltas = []
          @mutex.synchronize do
            collect_side_deltas(:bid, @bids, bids, ts_ms, deltas)
            collect_side_deltas(:ask, @asks, asks, ts_ms, deltas)
            @last_update_id = Integer(final_u)
          end
          fire_deltas(deltas)
          self
        end

        def top_bids(limit = 5)
          ordered_levels(@bids, descending: true, limit: limit)
        end

        def top_asks(limit = 5)
          ordered_levels(@asks, descending: false, limit: limit)
        end

        def best_bid
          top_bids(1).first
        end

        def best_ask
          top_asks(1).first
        end

        def mid
          bid = best_bid
          ask = best_ask
          return nil if bid.nil? || ask.nil?

          (bid.first + ask.first) / 2
        end

        def empty?
          @mutex.synchronize { @bids.empty? && @asks.empty? }
        end

        private

        def normalize_event_time_ms(event_time)
          return (Time.now.to_f * 1000).to_i if event_time.nil?

          Integer(event_time)
        end

        def collect_side_deltas(side_sym, side_map, updates, ts_ms, deltas_out)
          Array(updates).each do |(price, qty)|
            p = to_decimal(price)
            q = to_decimal(qty)
            prev_q = side_map[p] || BigDecimal('0')
            best_before = best_price_on_side(side_map, side_sym)

            if q.zero?
              next if prev_q.zero?

              was_best = !best_before.nil? && p == best_before
              side_map.delete(p)
              deltas_out << {
                side: side_sym,
                price: p,
                prev_qty: prev_q,
                new_qty: BigDecimal('0'),
                action: :remove,
                was_best: was_best,
                ts_ms: ts_ms
              }
            elsif prev_q.zero?
              side_map[p] = q
              deltas_out << {
                side: side_sym,
                price: p,
                prev_qty: BigDecimal('0'),
                new_qty: q,
                action: :add,
                was_best: false,
                ts_ms: ts_ms
              }
            elsif prev_q != q
              side_map[p] = q
              action = q > prev_q ? :increase : :decrease
              deltas_out << {
                side: side_sym,
                price: p,
                prev_qty: prev_q,
                new_qty: q,
                action: action,
                was_best: false,
                ts_ms: ts_ms
              }
            end
          end
        end

        def best_price_on_side(side_map, side_sym)
          return nil if side_map.empty?

          side_sym == :bid ? side_map.keys.max : side_map.keys.min
        end

        def fire_deltas(deltas)
          listeners = @listener_mutex.synchronize { @delta_listeners.dup }
          deltas.each do |delta|
            listeners.each { |cb| cb.call(delta) }
          end
        end

        def fire_resets
          listeners = @listener_mutex.synchronize { @reset_listeners.dup }
          listeners.each(&:call)
        end

        def build_side(levels)
          Array(levels).each_with_object({}) do |(price, qty), acc|
            p = to_decimal(price)
            q = to_decimal(qty)
            next if q <= 0

            acc[p] = q
          end
        end

        def ordered_levels(side, descending:, limit:)
          @mutex.synchronize do
            sorted = descending ? side.sort.reverse : side.sort
            sorted.first(limit)
          end
        end

        def to_decimal(value)
          return value if value.is_a?(BigDecimal)

          BigDecimal(value.to_s)
        end
      end
    end
  end
end
