# frozen_string_literal: true

require 'bigdecimal'

module CoindcxBot
  module Orderflow
    # Heuristic: repeated refills near executed size at the same price suggest hidden liquidity.
    class IcebergDetector
      DEFAULT_WINDOW_MS = 2_000
      DEFAULT_MIN_REFILLS = 3
      DEFAULT_QTY_TOLERANCE = BigDecimal('0.2')

      def initialize(bus:, config:)
        @bus = bus
        @config = config
        @mutex = Mutex.new
        @rows = {} # "pair|source|side|price" => { fill_qty:, refill_qty:, refills:, last_ts: }
      end

      def on_trade(trade)
        pair = trade[:pair].to_s
        source = (trade[:source] || :coindcx).to_sym
        price = BigDecimal(trade[:price].to_s)
        qty = BigDecimal(trade[:size].to_s)
        side = aggressor_side(trade[:side])
        return unless side

        ts = trade[:ts]
        ts_ms = normalize_ts_ms(ts)
        key = row_key(pair, source, side, price)
        @mutex.synchronize do
          row = @rows[key] ||= { fill_qty: BigDecimal('0'), refill_qty: BigDecimal('0'), refills: 0, last_ts: ts_ms }
          row[:fill_qty] += qty
          row[:last_ts] = ts_ms
          prune_unlocked!(ts_ms)
        end
      end

      # Book add / size increase at a resting level (+:add+, +:increase+ from LocalBook deltas).
      def feed_book_delta(pair:, source:, delta:)
        return unless %i[add increase].include?(delta[:action])

        side = book_side_to_aggressor_target(delta[:side])
        price = delta[:price]
        added = delta[:action] == :add ? delta[:new_qty] : (delta[:new_qty] - delta[:prev_qty])
        return if added <= 0

        ts_ms = Integer(delta[:ts_ms])
        key = row_key(pair, source, side, price)
        @mutex.synchronize do
          row = @rows[key] ||= { fill_qty: BigDecimal('0'), refill_qty: BigDecimal('0'), refills: 0, last_ts: ts_ms }
          row[:refill_qty] += added
          row[:refills] += 1
          row[:last_ts] = ts_ms
          prune_unlocked!(ts_ms)
          maybe_emit_unlocked!(key: key, pair: pair, source: source, side: side, price: price, row: row, ts_ms: ts_ms)
        end
      end

      # CoinDCX snapshot transition: detect size increases at existing prices (refill proxy).
      def feed_coindcx_levels(pair:, source:, prev_side:, new_side:, side:, ts_ms:)
        new_side.each do |price_str, new_qty|
          prev_q = prev_side[price_str]
          next if prev_q.nil?

          new_q = new_qty.to_f
          next unless new_q > prev_q.to_f

          added = BigDecimal((new_q - prev_q.to_f).to_s)
          delta_like = {
            side: side,
            price: BigDecimal(price_str.to_s),
            new_qty: BigDecimal(new_q.to_s),
            prev_qty: BigDecimal(prev_q.to_s),
            action: :increase,
            ts_ms: ts_ms
          }
          feed_book_delta(pair: pair, source: source, delta: delta_like)
        end
      end

      private

      def aggressor_side(trade_side)
        s = trade_side.to_s.downcase
        return :ask if s == 'buy'
        return :bid if s == 'sell'

        nil
      end

      # Iceberg rests on the passive side: bid iceberg -> bid book adds; fills hit bids with sell aggressor.
      def book_side_to_aggressor_target(book_side)
        book_side == :bid ? :bid : :ask
      end

      def row_key(pair, source, side, price)
        "#{pair}|#{source}|#{side}|#{price.to_s('F')}"
      end

      def normalize_ts_ms(ts)
        f = ts.nil? ? Time.now.to_f * 1000 : ts.to_f
        f > 1_000_000_000_000 ? f.to_i : (f * 1000).to_i
      end

      def prune_unlocked!(now_ms)
        win = window_ms
        @rows.delete_if { |_, row| now_ms - row[:last_ts] > win * 2 }
      end

      def maybe_emit_unlocked!(key:, pair:, source:, side:, price:, row:, ts_ms:)
        return if row[:refills] < min_refills
        return if row[:fill_qty] <= 0

        tol = qty_tolerance
        diff_ratio = ((row[:refill_qty] - row[:fill_qty]).abs / row[:fill_qty])
        return if diff_ratio > tol

        score = [row[:refills].to_f, (BigDecimal('1') - diff_ratio).to_f].min
        @bus.publish(
          :'liquidity.iceberg.suspected',
          {
            source: source,
            symbol: pair,
            side: side,
            price: price,
            score: BigDecimal(score.to_s).round(4),
            ts: ts_ms,
            pair: pair
          }
        )
        @rows.delete(key)
      end

      def section
        s = @config.respond_to?(:orderflow_section) ? @config.orderflow_section : {}
        sec = s[:iceberg]
        sec.is_a?(Hash) ? sec : {}
      end

      def window_ms
        Integer(section.fetch(:window_ms, DEFAULT_WINDOW_MS))
      rescue ArgumentError, TypeError
        DEFAULT_WINDOW_MS
      end

      def min_refills
        Integer(section.fetch(:min_refills, DEFAULT_MIN_REFILLS))
      rescue ArgumentError, TypeError
        DEFAULT_MIN_REFILLS
      end

      def qty_tolerance
        BigDecimal(section.fetch(:qty_tolerance, DEFAULT_QTY_TOLERANCE).to_s)
      rescue ArgumentError, TypeError
        DEFAULT_QTY_TOLERANCE
      end
    end
  end
end
