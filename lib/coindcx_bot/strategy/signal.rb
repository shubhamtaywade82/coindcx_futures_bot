# frozen_string_literal: true

module CoindcxBot
  module Strategy
    Signal = Struct.new(:action, :pair, :side, :stop_price, :reason, :metadata, keyword_init: true) do
      def initialize(**kwargs)
        kwargs[:metadata] = {} if kwargs[:metadata].nil?
        super(**kwargs)
      end
    end
  end
end
