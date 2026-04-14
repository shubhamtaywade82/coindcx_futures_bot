# frozen_string_literal: true

module CoindcxBot
  module SmcConfluence
    # Premium / discount vs a single range (e.g. swing or rolling window high/low).
    class PremiumDiscount
      EPSILON_RATIO = 1e-12

      def initialize(range_high:, range_low:)
        @range_high = range_high.to_f
        @range_low = range_low.to_f
      end

      def equilibrium
        (@range_high + @range_low) / 2.0
      end

      def range?
        (@range_high - @range_low).abs > EPSILON_RATIO
      end

      def premium?(close)
        return false unless range?

        close.to_f > equilibrium
      end

      def discount?(close)
        return false unless range?

        close.to_f < equilibrium
      end
    end
  end
end
