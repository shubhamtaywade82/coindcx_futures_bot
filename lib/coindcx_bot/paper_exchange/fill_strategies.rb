# frozen_string_literal: true

module CoindcxBot
  module PaperExchange
    # Pluggable fill simulation; all modes delegate to Execution::FillEngine for price rules.
    module FillStrategies
      class CandleReplay
        def initialize(fill_engine)
          @fill_engine = fill_engine
        end

        def evaluate(order, ltp:, high:, low:)
          @fill_engine.evaluate(order, ltp: ltp, high: high, low: low)
        end
      end

      class BookReplay
        def initialize(fill_engine)
          @fill_engine = fill_engine
        end

        # Until depth matching ships, fall back to candle-style touch rules with synthetic LTP.
        def evaluate(order, ltp:, high:, low:)
          @fill_engine.evaluate(order, ltp: ltp, high: high, low: low)
        end
      end

      class LiveShadow
        def initialize(fill_engine)
          @fill_engine = fill_engine
        end

        def evaluate(order, ltp:, high:, low:)
          @fill_engine.evaluate(order, ltp: ltp, high: high, low: low)
        end
      end

      def self.for_mode(mode, fill_engine)
        case mode.to_s
        when 'book' then BookReplay.new(fill_engine)
        when 'live' then LiveShadow.new(fill_engine)
        else CandleReplay.new(fill_engine)
        end
      end
    end
  end
end
