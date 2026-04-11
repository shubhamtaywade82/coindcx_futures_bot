# frozen_string_literal: true

module CoindcxBot
  module Tui
    # Cycles configured `pairs` for order-book focus and header labeling.
    class FocusRing
      def initialize(symbols)
        @symbols = Array(symbols).map(&:to_s)
        @i = 0
      end

      def current
        return nil if @symbols.empty?

        @symbols[@i % @symbols.size]
      end

      def advance!
        @i += 1
      end

      def select_absolute!(n)
        return if @symbols.empty?

        @i = Integer(n) % @symbols.size
      rescue ArgumentError, TypeError
        nil
      end
    end
  end
end
