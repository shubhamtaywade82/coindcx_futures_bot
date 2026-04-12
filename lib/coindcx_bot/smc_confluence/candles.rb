# frozen_string_literal: true

module CoindcxBot
  module SmcConfluence
    # Adapts {Dto::Candle} arrays to the hash shape expected by {Engine}.
    # Volume defaults to 0 when missing; volume-profile layers then stay inactive until volume is present.
    module Candles
      module_function

      def from_dto(candles)
        Array(candles).map { |c| dto_to_hash(c) }
      end

      def dto_to_hash(candle)
        t = candle.time
        ts =
          case t
          when Integer then t
          when Time then t.to_i
          else
            Integer(t.to_i)
          end
        {
          timestamp: ts,
          open: candle.open,
          high: candle.high,
          low: candle.low,
          close: candle.close,
          volume: candle.volume
        }
      end
    end
  end
end
