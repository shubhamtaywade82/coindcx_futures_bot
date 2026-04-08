# frozen_string_literal: true

module CoindcxBot
  module Gateways
    class OrderGateway
      include Concerns::ErrorMapping

      def initialize(client:, order_defaults: {})
        @client = client
        @order_defaults = order_defaults.transform_keys(&:to_sym)
      end

      def create(order:)
        guard_call { @client.futures.orders.create(order: deep_stringify(merge_defaults(order))) }
      end

      def list(filters = {})
        guard_call { @client.futures.orders.list(filters) }
      end

      def cancel(attributes)
        guard_call { @client.futures.orders.cancel(deep_stringify(attributes)) }
      end

      private

      def merge_defaults(order)
        @order_defaults.merge(order.transform_keys(&:to_sym))
      end

      def deep_stringify(hash)
        hash.transform_keys(&:to_s).transform_values do |v|
          v.is_a?(Hash) ? deep_stringify(v) : v
        end
      end
    end
  end
end
