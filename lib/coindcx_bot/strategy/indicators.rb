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

      # Last candle volume vs simple average of prior `lookback` volumes (excludes last bar from avg).
      def volume_ratio_last(candles, lookback:)
        return nil if candles.size < lookback + 1

        vols = candles.map { |c| BigDecimal(c.volume.to_s) }
        last = vols.last
        window = vols.last(lookback + 1).first(lookback)
        avg = window.sum(BigDecimal('0')) / lookback
        return nil unless avg.positive?

        last / avg
      end

      # Strict higher highs and higher lows over the last `bars` closed candles (long). Short uses lower highs/lows.
      def directional_structure?(candles, trend, bars:)
        return true if bars.to_i <= 1

        slice = candles.last(bars)
        return false if slice.size < bars

        case trend
        when :long
          slice.each_cons(2) { |a, b| return false unless b.high > a.high && b.low > a.low }
        when :short
          slice.each_cons(2) { |a, b| return false unless b.high < a.high && b.low < a.low }
        else
          return false
        end
        true
      end

      # Wilder-style ADX using the last `period` of smoothed DX values; returns 0..100 or nil if not enough data.
      def adx_last(candles, period: 14)
        n = Integer(period)
        return nil if candles.size < (2 * n) + 2

        trs = []
        plus_dm = []
        minus_dm = []
        candles.each_cons(2) do |prev, cur|
          up_move = cur.high - prev.high
          down_move = prev.low - cur.low
          plus_dm << (up_move > down_move && up_move.positive? ? up_move : BigDecimal('0'))
          minus_dm << (down_move > up_move && down_move.positive? ? down_move : BigDecimal('0'))
          hl = cur.high - cur.low
          hc = (cur.high - prev.close).abs
          lc = (cur.low - prev.close).abs
          trs << [hl, hc, lc].max
        end

        atr_w = trs.first(n).sum(BigDecimal('0')) / n
        p_dm_w = plus_dm.first(n).sum(BigDecimal('0')) / n
        m_dm_w = minus_dm.first(n).sum(BigDecimal('0')) / n
        dx_history = []

        (n...trs.size).each do |i|
          atr_w = atr_w - (atr_w / n) + trs[i]
          p_dm_w = p_dm_w - (p_dm_w / n) + plus_dm[i]
          m_dm_w = m_dm_w - (m_dm_w / n) + minus_dm[i]
          next unless atr_w.positive?

          p_di = (BigDecimal('100') * p_dm_w) / atr_w
          m_di = (BigDecimal('100') * m_dm_w) / atr_w
          denom = p_di + m_di
          dx =
            if denom.positive?
              (BigDecimal('100') * (p_di - m_di).abs) / denom
            else
              BigDecimal('0')
            end
          dx_history << dx
        end

        return nil if dx_history.size < n

        adx = dx_history.first(n).sum(BigDecimal('0')) / n
        (n...dx_history.size).each do |i|
          adx = adx - (adx / n) + (dx_history[i] / n)
        end
        adx
      end
    end
  end
end
