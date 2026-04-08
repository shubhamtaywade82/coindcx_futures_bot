# frozen_string_literal: true

module CoindcxBot
  module Dto
    Candle = Struct.new(:time, :open, :high, :low, :close, :volume) do
      def initialize(time:, open:, high:, low:, close:, volume: 0)
        super(time, open, high, low, close, volume)
      end
    end
  end
end
