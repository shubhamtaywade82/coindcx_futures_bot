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

      # CoinDCX futures LTP channel — see CoinDCX::WS::PublicChannels.futures_price_stats
      def subscribe_futures_prices(instrument:, &block)
        channel = CoinDCX::WS::PublicChannels.futures_price_stats(instrument: instrument)
        @ws.subscribe_public(channel_name: channel, event_name: 'price-change') do |payload|
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
        h = payload.is_a?(Hash) ? payload.transform_keys { |k| k.to_sym } : {}
        price_raw = h[:p] || h[:last_price] || h[:ltp] || h[:price]
        return nil if price_raw.nil?

        # Always key by the subscribed instrument so PositionTracker matches config.pairs
        # (payload `s` often differs from REST / bot.yml codes).
        Dto::Tick.new(
          pair: instrument,
          price: BigDecimal(price_raw.to_s),
          received_at: Time.now
        )
      end
    end
  end
end
