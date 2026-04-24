# frozen_string_literal: true

module CoindcxBot
  module SmcConfluence
    # Computes wick rejection quality when price is inside an OB zone.
    # Always runs in Engine (no feature flag) since it only activates when in_bull_ob or in_bear_ob.
    module MitigationAnalyzer
      STRONG_WICK_RATIO   = 0.5
      MODERATE_WICK_RATIO = 0.25

      module_function

      # Returns { reaction_strength: String }
      def detect(candle, in_bull_ob, in_bear_ob)
        return { reaction_strength: 'none' } unless in_bull_ob || in_bear_ob

        high  = candle[:high].to_f
        low   = candle[:low].to_f
        open  = candle[:open].to_f
        close = candle[:close].to_f
        range = high - low

        return { reaction_strength: 'none' } if range <= 0

        wick_ratio = if in_bull_ob
                       lower_wick(open, close, low) / range
                     else
                       upper_wick(open, close, high) / range
                     end

        strength = if wick_ratio >= STRONG_WICK_RATIO
                     'strong'
                   elsif wick_ratio >= MODERATE_WICK_RATIO
                     'moderate'
                   else
                     'weak'
                   end

        { reaction_strength: strength }
      end

      # --- Private Internal ---

      def lower_wick(open, close, low)
        [open, close].min - low
      end

      def upper_wick(open, close, high)
        high - [open, close].max
      end

      private_class_method :lower_wick, :upper_wick
    end
  end
end
