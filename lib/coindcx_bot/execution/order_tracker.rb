# frozen_string_literal: true

require 'bigdecimal'

module CoindcxBot
  module Execution
    # Manages the lifecycle of individual orders and provides idempotency:
    #   pending → submitted → filled / partially_filled / rejected / cancelled
    #
    # Each order is anchored by a client_order_id generated before placement so
    # a crash between "order sent" and "journal written" can be detected.
    class OrderTracker
      TERMINAL_STATES = %w[filled rejected cancelled].freeze

      def initialize(journal:, logger: nil)
        @journal = journal
        @logger  = logger
      end

      # Called immediately before placing an entry order — anchors idempotency.
      def begin_entry(client_order_id:, pair:, side:, quantity:)
        @journal.orders_insert(
          client_order_id: client_order_id,
          pair:            pair.to_s,
          side:            side.to_s,
          quantity:        quantity.to_s,
          order_type:      'market_entry'
        )
      end

      # Called after the exchange acknowledges the order and returns an ID.
      def on_submitted(client_order_id:, exchange_order_id:)
        return unless exchange_order_id && !exchange_order_id.to_s.strip.empty?

        @journal.orders_update_submitted(
          client_order_id: client_order_id,
          exchange_order_id: exchange_order_id.to_s
        )
      end

      # Called when the broker rejects/fails before exchange acknowledgement.
      def on_rejected(client_order_id:)
        @journal.orders_update_state(client_order_id: client_order_id, state: 'rejected')
      end

      # Called by WsFillHandler with actual execution data.
      # Updates the fill in the orders table and, when a position_id is linked,
      # backfills the position's entry_price with the real fill price.
      def on_fill(client_order_id: nil, exchange_order_id: nil,
                  fill_price:, filled_quantity:, fees_usdt:, state: 'filled')
        @journal.orders_update_fill(
          client_order_id:  client_order_id,
          exchange_order_id: exchange_order_id,
          fill_price:       fill_price,
          filled_quantity:  filled_quantity,
          fees_usdt:        fees_usdt,
          state:            state
        )

        order = if client_order_id
                  @journal.orders_find_by_client_id(client_order_id)
                elsif exchange_order_id
                  @journal.orders_find_by_exchange_id(exchange_order_id)
                end

        return unless order&.dig(:position_id) && fill_price

        @journal.update_position_entry_price(order[:position_id], fill_price)
        @logger&.info(
          "[order_tracker] pos #{order[:position_id]} entry_price → #{fill_price} (actual fill)"
        )
      end

      # Links the orders row to the journal position created after order placement.
      def link_position(client_order_id:, position_id:)
        @journal.orders_link_position(client_order_id: client_order_id, position_id: position_id)
      end
    end
  end
end
