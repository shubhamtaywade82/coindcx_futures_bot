# frozen_string_literal: true

require 'bigdecimal'
require 'json'

module CoindcxBot
  module Exchanges
    module Binance
      # Best bid / best ask push stream (low bandwidth mid proxy).
      class BookTickerWs
        DEFAULT_HOST = 'wss://fstream.binance.com'

        def initialize(symbol:, coindcx_pair: nil, base_ws: DEFAULT_HOST, logger: nil, transport: nil)
          @binance_symbol = symbol.to_s.upcase
          @coindcx_pair = coindcx_pair&.to_s
          @stream_sym = symbol.to_s.downcase
          @url = "#{base_ws}/stream?streams=#{@stream_sym}@bookTicker"
          @logger = logger
          @transport = transport
          reset_callbacks
        end

        attr_reader :url

        def on_quote(&block)
          (@on_quote = block
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

        private

        def reset_callbacks
          @on_quote = nil
          @on_open = nil
          @on_close = nil
          @on_error = nil
        end

        def dispatch_message(raw)
          payload = decode_payload(raw)
          return unless payload && payload['e'] == 'bookTicker'

          pair = @coindcx_pair || @binance_symbol
          @on_quote&.call(
            pair: pair,
            best_bid: BigDecimal(payload['b'].to_s),
            best_ask: BigDecimal(payload['a'].to_s),
            ts: Integer(payload['E'] || payload['T'] || 0),
            source: :binance
          )
        rescue StandardError => e
          @on_error&.call(e)
        end

        def decode_payload(raw)
          parsed = raw.is_a?(String) ? JSON.parse(raw) : raw
          parsed.is_a?(Hash) ? (parsed['data'] || parsed) : nil
        rescue JSON::ParserError
          nil
        end

        def default_transport
          require_relative 'depth_ws/websocket_client_simple_transport'
          DepthWs::WebsocketClientSimpleTransport.new(logger: @logger)
        end
      end
    end
  end
end
