# frozen_string_literal: true

module CoindcxBot
  module Gateways
    class AccountGateway
      include Concerns::ErrorMapping

      def initialize(client:)
        @client = client
      end

      def futures_wallet(attributes = {})
        guard_call { @client.futures.wallets.fetch_details(attributes) }
      end

      def list_positions(attributes = {})
        guard_call { @client.futures.positions.list(attributes) }
      end

      def exit_position(attributes)
        guard_call { @client.futures.positions.exit_position(attributes) }
      end

      def cancel_all_open_orders_for_position(attributes)
        guard_call { @client.futures.positions.cancel_all_open_orders_for_position(attributes) }
      end
    end
  end
end
