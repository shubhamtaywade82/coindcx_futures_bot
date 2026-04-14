# frozen_string_literal: true

module CoindcxBot
  module Tui
    # Renders a Unicode sparkline from a series of numeric values.
    #
    #   Sparkline.render([100.1, 100.5, 99.8, 100.2, 101.0], width: 10)
    #   # => "▃▅▁▃█"
    #
    # The block characters map values linearly between the series min and max:
    #   ▁ ▂ ▃ ▄ ▅ ▆ ▇ █
    #
    module Sparkline
      BLOCKS = %w[▁ ▂ ▃ ▄ ▅ ▆ ▇ █].freeze

      module_function

      # @param values [Array<Numeric>] price or metric series (oldest → newest).
      # @param width [Integer] max visible characters to emit.
      # @return [String] Unicode sparkline (no ANSI color).
      def render(values, width: 20)
        pts = Array(values).last(width).map { |v| v.to_f }
        return '' if pts.empty?

        lo = pts.min
        hi = pts.max
        span = hi - lo

        pts.map do |v|
          idx = span.zero? ? 3 : ((v - lo) / span * (BLOCKS.size - 1)).round
          idx = idx.clamp(0, BLOCKS.size - 1)
          BLOCKS[idx]
        end.join
      end
    end
  end
end
