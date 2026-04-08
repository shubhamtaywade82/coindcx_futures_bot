# frozen_string_literal: true

require 'bigdecimal'

module CoindcxBot
  module Strategy
    module Indicators
      module_function

      def ema_last(values, period)
        arr = values.map { |v| BigDecimal(v.to_s) }
        return nil if arr.size < period

        ema = arr.first(period).sum(BigDecimal('0')) / period
        k = BigDecimal('2') / (BigDecimal(period) + 1)
        arr.drop(period).each do |price|
          ema = (price * k) + (ema * (BigDecimal('1') - k))
        end
        ema
      end

      # Simple SMA of true range (Wilder omitted for clarity — sufficient as a volatility tape).
      def atr(candles, period)
        return nil if candles.size < period + 1

        trs = []
        candles.each_cons(2) do |prev, cur|
          hl = cur.high - cur.low
          hc = (cur.high - prev.close).abs
          lc = (cur.low - prev.close).abs
          trs << [hl, hc, lc].max
        end
        slice = trs.last(period)
        slice.sum(BigDecimal('0')) / period
      end

      # Trend pressure: EMA separation normalized by ATR (higher => stronger directional tape).
      def ema_atr_ratio(candles, fast:, slow:, atr_period:)
        closes = candles.map(&:close)
        ef = ema_last(closes, fast)
        es = ema_last(closes, slow)
        a = atr(candles, atr_period)
        return nil unless ef && es && a&.positive?

        (ef - es).abs / a
      end
    end
  end
end
