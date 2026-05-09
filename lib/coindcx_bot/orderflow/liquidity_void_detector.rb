# frozen_string_literal: true

require 'bigdecimal'

module CoindcxBot
  module Orderflow
    # Flags unusually wide empty gaps between populated L2 levels near the touch.
    class LiquidityVoidDetector
      DEFAULT_DEPTH = 50
      DEFAULT_MULTIPLIER = BigDecimal('5')

      def initialize(bus:, config:)
        @bus = bus
        @config = config
      end

      # @param bids [Hash] price_string => qty (OrderBookStore shape)
      # @param asks [Hash]
      def on_book(pair:, bids:, asks:, source:, ts_ms: nil)
        ts = ts_ms || (Time.now.to_f * 1000).to_i
        check_side(pair: pair, source: source, side: :ask, levels: top_asks(asks, depth), ts: ts)
        check_side(pair: pair, source: source, side: :bid, levels: top_bids(bids, depth), ts: ts)
      end

      private

      def top_asks(asks, limit)
        asks.keys.map { |k| BigDecimal(k.to_s) }.sort.first(limit)
      end

      def top_bids(bids, limit)
        bids.keys.map { |k| BigDecimal(k.to_s) }.sort.reverse.first(limit)
      end

      def check_side(pair:, source:, side:, levels:, ts:)
        return if levels.size < 3

        gaps = []
        (1...levels.size).each do |i|
          gaps << (levels[i] - levels[i - 1]).abs
        end
        return if gaps.empty?

        avg = gaps.inject(BigDecimal('0')) { |acc, g| acc + g } / gaps.size
        return if avg <= 0

        mult = multiplier
        gaps.each_with_index do |gap, idx|
          next unless gap > avg * mult

          void_start = side == :ask ? levels[idx] : levels[idx + 1]
          void_end = side == :ask ? levels[idx + 1] : levels[idx]
          @bus.publish(
            :'liquidity.void.detected',
            {
              source: source,
              symbol: pair,
              side: side,
              void_start: void_start,
              void_end: void_end,
              multiplier: mult,
              ts: ts,
              pair: pair
            }
          )
        end
      end

      def section
        s = @config.respond_to?(:orderflow_section) ? @config.orderflow_section : {}
        sec = s[:void]
        sec.is_a?(Hash) ? sec : {}
      end

      def depth
        Integer(section.fetch(:depth, DEFAULT_DEPTH))
      rescue ArgumentError, TypeError
        DEFAULT_DEPTH
      end

      def multiplier
        BigDecimal(section.fetch(:multiplier, DEFAULT_MULTIPLIER).to_s)
      rescue ArgumentError, TypeError
        DEFAULT_MULTIPLIER
      end
    end
  end
end
