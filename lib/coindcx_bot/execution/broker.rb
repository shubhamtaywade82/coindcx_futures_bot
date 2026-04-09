# frozen_string_literal: true

module CoindcxBot
  module Execution
    class Broker
      def place_order(order)
        raise NotImplementedError
      end

      def cancel_order(order_id)
        raise NotImplementedError
      end

      def open_positions
        raise NotImplementedError
      end

      def open_position_for(pair)
        raise NotImplementedError
      end

      def close_position(pair:, side:, quantity:, ltp:, position_id: nil)
        raise NotImplementedError
      end

      def paper?
        false
      end

      def metrics
        {}
      end
    end
  end
end
