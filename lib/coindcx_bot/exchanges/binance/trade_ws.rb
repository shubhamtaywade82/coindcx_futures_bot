# frozen_string_literal: true

require 'bigdecimal'
require 'json'

module CoindcxBot
  module Exchanges
    module Binance
      # Binance USDⓈ-M Futures combined-stream @aggTrade feed (faster aggregation than raw @trade).
      class TradeWs
        DEFAULT_HOST = 'wss://fstream.binance.com'

        def initialize(symbol:, coindcx_pair: nil, base_ws: DEFAULT_HOST, logger: nil, transport: nil)
          @binance_symbol = symbol.to_s.upcase
          @coindcx_pair = coindcx_pair&.to_s
          @stream_sym = symbol.to_s.downcase
          @url = "#{base_ws}/stream?streams=#{@stream_sym}@aggTrade"
          @logger = logger
          @transport = transport
          reset_callbacks
        end

        attr_reader :url, :coindcx_pair

        def on_trade(&block)
          (@on_trade = block
           self)
        end

        def on_open(&block)
          (@on_open = block
           self)
        end

        def on_close(&block)
          (@on_close = block
           self)
        end

        def on_error(&block)
          (@on_error = block
           self)
        end

        def connect
          @transport ||= default_transport
          @transport.connect(
            url: @url,
            on_message: ->(raw) { dispatch_message(raw) },
            on_open: -> { @on_open&.call },
            on_close: ->(info) { @on_close&.call(info) },
            on_error: ->(error) { @on_error&.call(error) }
          )
          self
        end

        def disconnect
          @transport&.close
          self
        end

        def self.trade_from_agg_payload(payload, coindcx_pair:, binance_symbol:)
          m = payload['m']
          aggressor_sell = m == true
          pair = coindcx_pair&.to_s
          pair = binance_symbol.to_s if pair.nil? || pair.empty?
          {
            pair: pair,
            price: BigDecimal(payload['p'].to_s),
            size: BigDecimal(payload['q'].to_s),
            side: aggressor_sell ? :sell : :buy,
            ts: Integer(payload['T']),
            source: :binance,
          }
        end

        private

        def reset_callbacks
          @on_trade = nil
          @on_open = nil
          @on_close = nil
          @on_error = nil
        end

        def dispatch_message(raw)
          payload = decode_payload(raw)
          return unless payload && payload['e'] == 'aggTrade'

          @on_trade&.call(build_trade(payload))
        rescue StandardError => e
          @on_error&.call(e)
        end

        def decode_payload(raw)
          parsed = raw.is_a?(String) ? JSON.parse(raw) : raw
          parsed.is_a?(Hash) ? (parsed['data'] || parsed) : nil
        rescue JSON::ParserError
          nil
        end

        def build_trade(payload)
          self.class.trade_from_agg_payload(
            payload,
            coindcx_pair: @coindcx_pair,
            binance_symbol: @binance_symbol
          )
        end

        def default_transport
          require_relative 'depth_ws/websocket_client_simple_transport'
          DepthWs::WebsocketClientSimpleTransport.new(logger: @logger)
        end
      end
    end
  end
end
