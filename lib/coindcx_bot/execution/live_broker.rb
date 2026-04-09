# frozen_string_literal: true

module CoindcxBot
  module Execution
    class LiveBroker < Broker
      def initialize(order_gateway:, account_gateway:, journal:, config:, exposure_guard:, logger: nil)
        @orders = order_gateway
        @account = account_gateway
        @journal = journal
        @config = config
        @exposure = exposure_guard
        @logger = logger
      end

      def place_order(order)
        result = @orders.create(order: order)
        return :failed if result.failure?

        @logger&.info("Live order placed: #{order}")
        :ok
      end

      def cancel_order(order_id)
        @orders.cancel(id: order_id)
      end

      def open_positions
        @journal.open_positions
      end

      def open_position_for(pair)
        @journal.open_positions.find { |r| r[:pair].to_s == pair.to_s }
      end

      def close_position(pair:, side:, quantity:, ltp:, position_id: nil)
        exit_exchange_for_pair(pair)
        :ok
      end

      def paper?
        false
      end

      private

      def exit_exchange_for_pair(pair)
        res = @account.list_positions
        if res.failure?
          @logger&.error("positions list failed: #{res.message}")
          return
        end

        normalize_rows(res.value).each do |row|
          next unless row[:pair].to_s == pair.to_s

          result = @account.exit_position(row)
          @logger&.warn("exit_position failed: #{result.message}") if result.failure?
        end
      end

      def normalize_rows(value)
        list =
          case value
          when Array then value
          when Hash
            value[:positions] || value['positions'] || value[:data] || value.values.find { |v| v.is_a?(Array) } || []
          else
            []
          end
        Array(list).map { |h| h.is_a?(Hash) ? h.transform_keys(&:to_sym) : {} }
      end
    end
  end
end
