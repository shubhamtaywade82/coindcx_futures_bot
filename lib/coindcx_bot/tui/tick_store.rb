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
        sym = symbol.to_s
        at = updated_at || Time.now
        @mutex.synchronize do
          prior = @ticks[sym]
          ch =
            if change_pct.nil?
              prior&.change_pct
            else
              change_pct.to_f
            end

          @ticks[sym] = Tick.new(
            symbol: sym,
            ltp: ltp.to_f,
            change_pct: ch,
            updated_at: at
          )
        end
      end

      def snapshot
        @mutex.synchronize { @ticks.dup.freeze }
      end

      def stale?(symbol, threshold_seconds: 5)
        tick = @mutex.synchronize { @ticks[symbol.to_s] }
        return true if tick.nil?

        (Time.now - tick.updated_at) > threshold_seconds
      end
    end
  end
end
