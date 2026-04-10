# frozen_string_literal: true

require 'bigdecimal'

module CoindcxBot
  module PaperExchange
    # Updates mark prices and runs the order fill engine for one pair (candle / LTP replay).
    class TickDispatcher
      def initialize(store:, orders_service:)
        @store = store
        @db = store.db
        @orders = orders_service
      end

      def dispatch!(user_id, pair:, ltp:, high: nil, low: nil)
        l = BigDecimal(ltp.to_s)
        hi = high ? BigDecimal(high.to_s) : l
        lo = low ? BigDecimal(low.to_s) : l
        now = @store.now_iso

        @db.execute(
          <<~SQL,
            INSERT INTO pe_mark_prices (pair, ltp, high, low, updated_at)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(pair) DO UPDATE SET
              ltp = excluded.ltp,
              high = excluded.high,
              low = excluded.low,
              updated_at = excluded.updated_at
          SQL
          [pair.to_s, l.to_s('F'), hi.to_s('F'), lo.to_s('F'), now]
        )

        @orders.process_tick(user_id, pair: pair, ltp: l, high: hi, low: lo)
      end
    end
  end
end
