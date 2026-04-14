# frozen_string_literal: true

module CoindcxBot
  module SmcConfluence
    # Three-candle fair value gap (ICT-style) from OHLC alone — no order flow.
    class Fvg
      attr_reader :side, :bar_index, :gap_low, :gap_high

      def initialize(side:, bar_index:, gap_low:, gap_high:)
        @side = side
        @bar_index = Integer(bar_index)
        gl = gap_low.to_f
        gh = gap_high.to_f
        @gap_low = [gl, gh].min
        @gap_high = [gl, gh].max
      end

      def invalidated_by_ohlc?(high, low)
        h = high.to_f
        l = low.to_f
        case side
        when :bullish
          l <= gap_low
        when :bearish
          h >= gap_high
        else
          false
        end
      end

      def overlaps_bar?(high, low)
        low.to_f <= gap_high && high.to_f >= gap_low
      end

      module Detector
        module_function

        # @param candles [Array<Hash>] engine-shaped bars (:open, :high, :low, :close)
        # @param i [Integer] index of the third candle (pattern completes at i)
        # @return [Fvg, nil]
        def at_index(candles, i)
          return nil if i < 2

          c1 = candles[i - 2]
          c3 = candles[i]
          h1 = c1[:high].to_f
          l1 = c1[:low].to_f
          h3 = c3[:high].to_f
          l3 = c3[:low].to_f

          if h1 < l3
            Fvg.new(side: :bullish, bar_index: i, gap_low: h1, gap_high: l3)
          elsif l1 > h3
            Fvg.new(side: :bearish, bar_index: i, gap_low: h3, gap_high: l1)
          end
        end
      end
    end
  end
end
