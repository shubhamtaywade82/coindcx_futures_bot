# frozen_string_literal: true

module CoindcxBot
  module Risk
    class ExposureGuard
      def initialize(config:)
        @max_positions = Integer(config.risk.fetch(:max_open_positions, 2))
        @max_leverage = Integer(config.risk.fetch(:max_leverage, 5))
      end

      attr_reader :max_positions, :max_leverage

      def within_concurrency?(open_count)
        open_count < @max_positions
      end

      def leverage_allowed?(requested)
        requested.nil? || requested <= @max_leverage
      end
    end
  end
end
