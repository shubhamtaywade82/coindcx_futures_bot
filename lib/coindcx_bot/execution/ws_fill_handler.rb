# frozen_string_literal: true

require 'bigdecimal'
require 'json'

module CoindcxBot
  module Execution
    # Processes CoinDCX `order-update` WebSocket events and routes fill data
    # to OrderTracker so positions get their actual fill price rather than the
    # LTP estimate recorded at signal time.
    #
    # CoinDCX order-update payload fields we rely on (best-effort — keys vary):
    #   client_order_id   our idempotency key
    #   id / order_id     exchange-side order ID
    #   status            "filled" | "partially_filled" | "cancelled" | "rejected"
    #   p / avg_price     average fill price
    #   q / cumulative_quantity  quantity filled so far
    #   fee / commission  fee paid in quote currency
    class WsFillHandler
      FILL_STATES    = %w[filled partially_filled].freeze
      TERMINAL_STATES = %w[filled cancelled rejected].freeze

      def initialize(order_tracker:, logger: nil)
        @tracker = order_tracker
        @logger  = logger
      end

      def handle(payload)
        h = normalize(payload)
        return unless h

        state = (h[:status] || h[:s] || '').to_s.downcase
        return unless FILL_STATES.include?(state) || TERMINAL_STATES.include?(state)

        client_oid   = h[:client_order_id]&.to_s
        exchange_oid = (h[:id] || h[:order_id] || h[:oid])&.to_s
        return unless client_oid || exchange_oid

        if FILL_STATES.include?(state)
          fill_price      = parse_decimal(h[:p] || h[:avg_price] || h[:fill_price] || h[:trade_price])
          filled_quantity = parse_decimal(h[:q] || h[:cumulative_quantity] || h[:filled_qty] || h[:cum_qty])
          fees_usdt       = parse_decimal(h[:fee] || h[:commission])

          return unless fill_price

          @tracker.on_fill(
            client_order_id:  client_oid,
            exchange_order_id: exchange_oid,
            fill_price:       fill_price,
            filled_quantity:  filled_quantity,
            fees_usdt:        fees_usdt,
            state:            state
          )
          @logger&.info(
            "[ws_fill] #{state} client_id=#{client_oid} exchange_id=#{exchange_oid} " \
            "fill=#{fill_price} qty=#{filled_quantity} fee=#{fees_usdt}"
          )
        elsif client_oid
          @tracker.on_rejected(client_order_id: client_oid) if state == 'rejected'
        end
      rescue StandardError => e
        @logger&.warn("[ws_fill] handle error: #{e.message}")
      end

      private

      def normalize(payload)
        case payload
        when Hash   then payload.transform_keys { |k| k.to_sym }
        when String then JSON.parse(payload, symbolize_names: true)
        end
      rescue JSON::ParserError
        nil
      end

      def parse_decimal(v)
        return nil if v.nil? || v.to_s.strip.empty?

        BigDecimal(v.to_s)
      rescue ArgumentError, TypeError
        nil
      end
    end
  end
end
