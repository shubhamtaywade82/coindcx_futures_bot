# frozen_string_literal: true

require 'bigdecimal'
require 'json'

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

        unless payload_instrument_matches?(instrument, h)
          return nil
        end

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
        h = coerce_payload_to_hash(payload)
        return {} if h.nil? || h.empty?

        merge_nested_quote_fields!(h)
        h
      end

      def coerce_payload_to_hash(payload)
        case payload
        when nil
          nil
        when String
          begin
            coerce_payload_to_hash(JSON.parse(payload))
          rescue JSON::ParserError
            {}
          end
        when Hash
          payload.transform_keys { |k| k.to_sym }
        when Array
          hashes = payload.select { |el| el.is_a?(Hash) }
          return {} if hashes.empty?

          hashes.map { |el| el.transform_keys { |k| k.to_sym } }.reduce { |acc, el| acc.merge(el) }
        else
          {}
        end
      end

      def merge_nested_quote_fields!(h)
        %i[data payload message d result].each do |key|
          inner = h[key]
          if inner.is_a?(String) && !inner.strip.empty?
            inner = begin
              parsed = JSON.parse(inner)
              parsed if parsed.is_a?(Hash)
            rescue JSON::ParserError
              nil
            end
          end
          next unless inner.is_a?(Hash)

          h.merge!(inner.transform_keys { |k| k.to_sym })
        end
        h
      end

      # CoinDCX broadcasts one Socket.IO event to all listeners; filter using payload instrument hints.
      def payload_instrument_matches?(instrument, h)
        hint = h[:s] || h[:pair] || h[:market] || h[:instrument] || h[:symbol]
        return true if hint.nil? || hint.to_s.strip.empty?

        compact_instrument_code(hint) == compact_instrument_code(instrument)
      end

      def compact_instrument_code(code)
        s = code.to_s.strip.upcase
        s = s.sub(/\A[A-Z]+-/, '')
        s.delete('_')
      end
    end
  end
end
