# frozen_string_literal: true

require 'bigdecimal'

module CoindcxBot
  module Exchanges
    module Binance
      # In-memory L2 book reconstructed from a REST snapshot plus Binance Futures
      # diff updates. Prices and quantities are BigDecimal for exact arithmetic.
      # Sequence validation is intentionally NOT this object's job — see
      # SequenceValidator and ResyncManager.
      class LocalBook
        attr_reader :last_update_id

        def initialize
          @bids = {}
          @asks = {}
          @last_update_id = nil
          @mutex = Mutex.new
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
          self
        end

        # Apply a Binance futures diffDepth update.
        # @param final_u [Integer] event final update id (becomes new last_update_id)
        # @param bids [Array<[price, qty]>] qty == 0 deletes the level
        # @param asks [Array<[price, qty]>] qty == 0 deletes the level
        def apply_diff!(final_u:, bids:, asks:)
          @mutex.synchronize do
            apply_levels(@bids, bids)
            apply_levels(@asks, asks)
            @last_update_id = Integer(final_u)
          end
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
          @bids.empty? && @asks.empty?
        end

        private

        def build_side(levels)
          Array(levels).each_with_object({}) do |(price, qty), acc|
            p = to_decimal(price)
            q = to_decimal(qty)
            next if q <= 0

            acc[p] = q
          end
        end

        def apply_levels(side, updates)
          Array(updates).each do |(price, qty)|
            p = to_decimal(price)
            q = to_decimal(qty)
            if q.zero?
              side.delete(p)
            else
              side[p] = q
            end
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
