# frozen_string_literal: true

require 'bigdecimal'

module CoindcxBot
  module Gateways
    class WsGateway
      include Concerns::ErrorMapping

      def initialize(client:)
        @client = client
        @ws = client.ws
      end

      def connect
        guard_call do
          @ws.connect
          self
        end
      end

      def disconnect
        @ws.disconnect
      end

      # Futures LTP freshness: CoinDCX emits `price-change` on @prices-futures sparingly; the
      # @trades-futures + `new-trade` stream usually updates more often when the book is active.
      # Both feed the same tick pipeline so the TUI/engine last-tick clock stays realistic.
      def subscribe_futures_prices(instrument:, &block)
        price_channel = CoinDCX::WS::PublicChannels.futures_price_stats(instrument: instrument)
        @ws.subscribe_public(channel_name: price_channel, event_name: 'price-change') do |payload|
          tick = normalize_tick(instrument, payload)
          block.call(tick) if tick
        end

        trade_channel = CoinDCX::WS::PublicChannels.futures_new_trade(instrument: instrument)
        @ws.subscribe_public(channel_name: trade_channel, event_name: 'new-trade') do |payload|
          tick = normalize_tick(instrument, payload)
          block.call(tick) if tick
        end

        Result.ok(self)
      rescue CoinDCX::Errors::Error => e
        map_coin_dcx_error(e)
      end

      def subscribe_order_updates(&block)
        @ws.subscribe_private(event_name: CoinDCX::WS::PrivateChannels::ORDER_UPDATE_EVENT, &block)
        Result.ok(self)
      rescue CoinDCX::Errors::Error => e
        map_coin_dcx_error(e)
      end

      private

      def normalize_tick(instrument, payload)
        h = normalize_payload_hash(payload)
        return nil if h.empty?

        price_raw = h[:p] || h[:last_price] || h[:ltp] || h[:price] || h[:trade_price] || h[:rate] || h[:px]
        return nil if price_raw.nil?

        change_raw = h[:pc] || h[:change_pct]
        change_pct = change_raw.nil? ? nil : BigDecimal(change_raw.to_s)

        Dto::Tick.new(
          pair: instrument,
          price: BigDecimal(price_raw.to_s),
          change_pct: change_pct,
          received_at: Time.now
        )
      end

      def normalize_payload_hash(payload)
        case payload
        when Hash
          payload.transform_keys { |k| k.to_sym }
        when Array
          first = payload.find { |el| el.is_a?(Hash) }
          first ? first.transform_keys { |k| k.to_sym } : {}
        else
          {}
        end
      end
    end
  end
end
