# frozen_string_literal: true

module CoindcxBot
  module Risk
    class ExposureGuard
      def initialize(config:)
        @max_positions = Integer(config.risk.fetch(:max_open_positions, 2))
        @max_leverage  = Integer(config.risk.fetch(:max_leverage, 5))

        # Correlation groups: array of arrays of pair strings.
        # max_correlated_positions caps how many pairs from the same group can be open at once.
        @correlation_groups        = config.correlation_groups
        @max_correlated_positions  = Integer(config.risk.fetch(:max_correlated_positions, 1))
      end

      attr_reader :max_positions, :max_leverage

      def within_concurrency?(open_count)
        open_count < @max_positions
      end

      def leverage_allowed?(requested)
        requested.nil? || requested <= @max_leverage
      end

      # Returns false when opening `new_pair` would exceed the per-group cap.
      # If `new_pair` belongs to no configured group this always returns true.
      def correlated_ok?(open_positions, new_pair)
        group = @correlation_groups.find { |g| g.include?(new_pair.to_s) }
        return true unless group

        open_in_group = open_positions.count { |p| group.include?(p[:pair].to_s) }
        open_in_group < @max_correlated_positions
      end
    end
  end
end
