# frozen_string_literal: true

require_relative '../dto/candle'

module CoindcxBot
  module Regime
    # Builds a T×D feature matrix from OHLCV with causal rolling z-scores.
    module Features
      module_function

      # @param candles [Array<Dto::Candle>] oldest first
      # @param zscore_lookback [Integer] window for mean/std at each t (uses indices t-lookback+1..t)
      # @return [Array<Array<Float>>] rows aligned with candles (skip rows with insufficient warmup)
      def raw_feature_rows(candles)
        return [] if candles.size < 5

        closes = candles.map { |c| to_f(c.close) }
        highs = candles.map { |c| to_f(c.high) }
        lows = candles.map { |c| to_f(c.low) }
        vols = candles.map { |c| to_f(c.volume) }
        log_ret = closes.each_cons(2).map { |a, b| Math.log(b / a) }
        # pad so index i in closes aligns: log_ret[i] = log(c[i]/c[i-1]) for i>=1
        lr = [0.0] + log_ret

        n = candles.size
        rows = []
        n.times do |t|
          next if t < 30 # warmup for longest internal window

          std20 = rolling_std(lr, t, 20)
          std5 = rolling_std(lr, t, 5)
          vol_ratio = std20.nil? || std20 < 1e-12 ? 1.0 : (std5 / std20)
          rsi = rsi_at(closes, t, 14)
          atr_n = atr_at(highs, lows, closes, t, 14)
          c = closes[t]
          atr_rel = c.nil? || c.zero? || atr_n.nil? ? 0.0 : (atr_n / c)
          roc10 = roc_at(closes, t, 10)
          vol_z = volume_zscore(vols, t, 20)

          rows << [
            (std20 || 0.0) * 100.0,
            vol_ratio.clamp(0.01, 10.0),
            (rsi || 50.0) / 100.0,
            atr_rel,
            (roc10 || 0.0).clamp(-0.5, 0.5),
            vol_z || 0.0
          ]
        end
        rows
      end

      # Aligns z-scored rows with candle indices: returns { index: candle_index, row: [Float] }
      def indexed_rows(candles, zscore_lookback:)
        raw = raw_feature_rows(candles)
        return [] if raw.empty?

        start_t = 30
        idx_map = (start_t...(start_t + raw.size)).to_a
        z = zscore_matrix(raw, zscore_lookback)
        idx_map.each_with_index.map do |candle_idx, i|
          { index: candle_idx, row: z[i] }
        end
      end

      # Full matrix (same length as raw_feature_rows) with causal z per column.
      def zscore_matrix(rows, lookback)
        return rows if rows.empty?

        t_len = rows.size
        d = rows.first.size
        out = Array.new(t_len) { Array.new(d, 0.0) }
        d.times do |j|
          lookback = [[lookback, 3].max, t_len].min
          t_len.times do |t|
            from = [0, t - lookback + 1].max
            col = (from..t).map { |i| rows[i][j] }
            m = mean(col)
            s = std_sample(col)
            out[t][j] = s.nil? || s < 1e-9 ? 0.0 : ((rows[t][j] - m) / s)
          end
        end
        out
      end

      def to_f(x)
        Float(x)
      rescue ArgumentError, TypeError
        0.0
      end

      def mean(arr)
        return 0.0 if arr.empty?

        arr.sum(0.0) / arr.size
      end

      def std_sample(arr)
        return nil if arr.size < 2

        m = mean(arr)
        v = arr.sum(0.0) { |x| (x - m)**2 } / (arr.size - 1)
        Math.sqrt(v)
      end

      def rolling_std(series, t, window)
        from = t - window + 1
        return nil if from.negative?

        slice = series[from..t]
        std_sample(slice)
      end

      def rsi_at(closes, t, period)
        return nil if t < period

        gains = 0.0
        losses = 0.0
        (t - period + 1..t).each do |i|
          delta = closes[i] - closes[i - 1]
          if delta.positive?
            gains += delta
          else
            losses += delta.abs
          end
        end
        avg_g = gains / period
        avg_l = losses / period
        return 100.0 if avg_l < 1e-12

        rs = avg_g / avg_l
        100.0 - (100.0 / (1.0 + rs))
      end

      def true_range(h, l, c_prev, c)
        hl = h - l
        hc = (h - c_prev).abs
        lc = (l - c_prev).abs
        [hl, hc, lc].max
      end

      def atr_at(highs, lows, closes, t, period)
        return nil if t < period

        trs = (t - period + 1..t).map do |i|
          true_range(highs[i], lows[i], closes[i - 1], closes[i])
        end
        trs.sum(0.0) / period
      end

      def roc_at(closes, t, period)
        return nil if t < period

        old = closes[t - period]
        return nil if old.nil? || old.zero?

        (closes[t] - old) / old
      end

      def volume_zscore(vols, t, window)
        from = t - window + 1
        return nil if from.negative?

        slice = vols[from..t]
        m = mean(slice)
        s = std_sample(slice)
        return 0.0 if s.nil? || s < 1e-12

        (vols[t] - m) / s
      end
    end
  end
end
