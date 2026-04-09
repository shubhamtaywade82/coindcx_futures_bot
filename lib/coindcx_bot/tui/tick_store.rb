# frozen_string_literal: true

module CoindcxBot
  module Tui
    class TickStore
      Tick = Data.define(:symbol, :ltp, :change_pct, :updated_at)

      def initialize
        @mutex = Mutex.new
        @ticks = {}
      end

      def update(symbol:, ltp:, change_pct: nil, updated_at: nil)
        at = updated_at || Time.now
        tick = Tick.new(
          symbol: symbol,
          ltp: ltp.to_f,
          change_pct: change_pct&.to_f,
          updated_at: at
        )
        @mutex.synchronize { @ticks[symbol] = tick }
      end

      def snapshot
        @mutex.synchronize { @ticks.dup.freeze }
      end

      def stale?(symbol, threshold_seconds: 5)
        tick = @mutex.synchronize { @ticks[symbol] }
        return true if tick.nil?

        (Time.now - tick.updated_at) > threshold_seconds
      end
    end
  end
end
