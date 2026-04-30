# frozen_string_literal: true

module CoindcxBot
  module SmcConfluence
    # Detects whether a genuine displacement (strong impulse move) occurred on the current bar.
    # Called by Engine after BOS/CHOCH detection when displacement_detection is enabled.
    module Displacement
      STRONG_ATR_MULTIPLE = 1.5
      WEAK_ATR_MULTIPLE   = 0.8
      VOLUME_SPIKE_RATIO  = 1.2
      ROLLING_VOL_WINDOW  = 20

      module_function

      # Returns { present: Boolean, strength: String, range_multiple: Float, volume_support: Boolean }
      def detect(candle, atr14, candles, bar_index)
        return absent if atr14.nil? || atr14 <= 0

        open  = candle[:open].to_f
        close = candle[:close].to_f
        high  = candle[:high].to_f
        low   = candle[:low].to_f
        vol   = candle[:volume].to_f

        body_size      = (close - open).abs
        candle_range   = high - low
        range_multiple = atr14.positive? ? (candle_range / atr14).round(2) : 0.0

        strength = if body_size >= STRONG_ATR_MULTIPLE * atr14
                     'strong'
                   elsif body_size >= WEAK_ATR_MULTIPLE * atr14
                     'moderate'
                   else
                     'weak'
                   end

        vol_support = volume_supported?(vol, candles, bar_index)

        { present: true, strength: strength, range_multiple: range_multiple, volume_support: vol_support }
      end

      def absent
        { present: false, strength: 'none', range_multiple: 0.0, volume_support: false }
      end

      def volume_supported?(vol, candles, bar_index)
        return false if vol <= 0

        from = [0, bar_index - ROLLING_VOL_WINDOW].max
        window = candles[from...bar_index]
        return false if window.empty?

        avg = window.sum { |c| c[:volume].to_f } / window.size
        avg.positive? && vol >= VOLUME_SPIKE_RATIO * avg
      end
    end
  end
end
