# frozen_string_literal: true

module CoindcxBot
  module Tui
    class TickStore
      Tick = Data.define(:symbol, :ltp, :change_pct, :updated_at, :bid, :ask, :mark)

      def initialize
        @mutex = Mutex.new
        @ticks = {}
      end

      def update(symbol:, ltp:, change_pct: nil, updated_at: nil, bid: nil, ask: nil, mark: nil)
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
          bid_v = bid.nil? ? prior&.bid : optional_float(bid)
          ask_v = ask.nil? ? prior&.ask : optional_float(ask)
          mark_v =
            if mark.nil?
              prior&.mark
            else
              optional_float(mark)
            end

          @ticks[sym] = Tick.new(
            symbol: sym,
            ltp: ltp.to_f,
            change_pct: ch,
            updated_at: at,
            bid: bid_v,
            ask: ask_v,
            mark: mark_v
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

      private

      def optional_float(v)
        return nil if v.nil? || v.to_s.strip.empty?

        v.to_f
      rescue ArgumentError, TypeError
        nil
      end
    end
  end
end
