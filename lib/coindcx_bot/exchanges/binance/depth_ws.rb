# frozen_string_literal: true

require 'bigdecimal'
require 'json'

module CoindcxBot
  module Exchanges
    module Binance
      # Connects to Binance USDⓈ-M Futures combined-stream depth WebSocket and
      # parses each `depthUpdate` payload into a typed `Event` for downstream
      # consumers.
      #
      # The transport is pluggable so specs can drive the parser without
      # touching the network. The default transport uses
      # `websocket-client-simple` (already in Gemfile.lock via the
      # coindcx-client dependency) and runs the read loop on its own thread —
      # mirroring the callback-driven shape of `Gateways::WsGateway`.
      class DepthWs
        DEFAULT_HOST = 'wss://fstream.binance.com'

        Event = Struct.new(
          :event_type,
          :symbol,
          :first_u,
          :final_u,
          :prev_u,
          :event_time,
          :tx_time,
          :bids,
          :asks,
          keyword_init: true
        )

        def initialize(symbol:, base_ws: DEFAULT_HOST, logger: nil, transport: nil)
          @symbol = symbol.to_s.downcase
          @url = "#{base_ws}/stream?streams=#{@symbol}@depth@100ms"
          @logger = logger
          @transport = transport
          reset_callbacks
        end

        attr_reader :url

        def on_event(&block)
          (@on_event = block
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

        # Public for multiplexed streams (same shape as single-stream decode).
        def self.build_depth_event(payload)
          Event.new(
            event_type: payload['e'],
            symbol: payload['s'],
            first_u: Integer(payload['U']),
            final_u: Integer(payload['u']),
            prev_u: payload['pu'].nil? ? nil : Integer(payload['pu']),
            event_time: payload['E'].to_i,
            tx_time: payload['T'].to_i,
            bids: parse_levels_static(payload['b']),
            asks: parse_levels_static(payload['a'])
          )
        end

        def self.parse_levels_static(rows)
          Array(rows).map { |(price, qty)| [BigDecimal(price.to_s), BigDecimal(qty.to_s)] }
        end

        private

        def reset_callbacks
          @on_event = nil
          @on_open = nil
          @on_close = nil
          @on_error = nil
        end

        def dispatch_message(raw)
          payload = decode_payload(raw)
          return unless payload && payload['e'] == 'depthUpdate'

          @on_event&.call(build_event(payload))
        rescue StandardError => e
          @on_error&.call(e)
        end

        def decode_payload(raw)
          parsed = raw.is_a?(String) ? JSON.parse(raw) : raw
          parsed.is_a?(Hash) ? (parsed['data'] || parsed) : nil
        rescue JSON::ParserError
          nil
        end

        def build_event(payload)
          self.class.build_depth_event(payload)
        end

        def parse_levels(rows)
          self.class.parse_levels_static(rows)
        end

        def default_transport
          require_relative 'depth_ws/websocket_client_simple_transport'
          DepthWs::WebsocketClientSimpleTransport.new(logger: @logger)
        end
      end
    end
  end
end
