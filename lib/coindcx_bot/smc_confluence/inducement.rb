# frozen_string_literal: true

module CoindcxBot
  module SmcConfluence
    # Detects inducement: weak structure points (equal highs/lows) that act as traps before
    # a real directional move. Called by Engine after liquidity sweep detection.
    module Inducement
      LOOKBACK     = 5
      EQUALITY_PCT = 0.001  # 0.1% tolerance for "equal" highs/lows

      module_function

      # Returns { present: Boolean, type: String, price: Float|nil, swept: Boolean }
      def detect(bar_index, candles)
        current = candles[bar_index]
        return absent if current.nil?

        current_close = current[:close].to_f
        current_high  = current[:high].to_f
        current_low   = current[:low].to_f

        from = [0, bar_index - LOOKBACK].max
        window = candles[from...bar_index]
        return absent if window.size < 2

        eq_highs = equal_highs(window)
        eq_lows  = equal_lows(window)

        if eq_highs
          swept = current_high > eq_highs * (1 + EQUALITY_PCT)
          { present: true, type: 'equal_highs', price: eq_highs, swept: swept }
        elsif eq_lows
          swept = current_low < eq_lows * (1 - EQUALITY_PCT)
          { present: true, type: 'equal_lows', price: eq_lows, swept: swept }
        elsif weak_higher_low?(window, current_close)
          { present: true, type: 'weak_hl', price: nil, swept: false }
        else
          absent
        end
      end

      # --- Private Internal ---

      def absent
        { present: false, type: 'none', price: nil, swept: false }
      end

      def equal_highs(candles)
        highs = candles.map { |c| c[:high].to_f }
        cluster = find_cluster(highs)
        cluster
      end

      def equal_lows(candles)
        lows = candles.map { |c| c[:low].to_f }
        cluster = find_cluster(lows)
        cluster
      end

      # Returns the cluster price if >= 2 values are within EQUALITY_PCT of each other, else nil.
      def find_cluster(values)
        values.each_with_index do |v, i|
          matches = values[(i + 1)..].select { |w| (v - w).abs / v <= EQUALITY_PCT }
          return v.round(8) if matches.size >= 1
        end
        nil
      end

      # Simple heuristic: last bar's low is a higher low but closes weakly (small body, wick-heavy)
      def weak_higher_low?(window, current_close)
        return false if window.size < 2

        last = window.last
        prev = window[-2]
        return false if last.nil? || prev.nil?

        last_low  = last[:low].to_f
        prev_low  = prev[:low].to_f
        last_open = last[:open].to_f
        last_close = last[:close].to_f

        body = (last_close - last_open).abs
        range = last[:high].to_f - last_low
        wick_heavy = range > 0 && body / range < 0.35

        last_low > prev_low && wick_heavy
      end

      private_class_method :equal_highs, :equal_lows, :find_cluster, :weak_higher_low?
    end
  end
end
