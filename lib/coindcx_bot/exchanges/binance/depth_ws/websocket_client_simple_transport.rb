# frozen_string_literal: true

require 'websocket-client-simple'

module CoindcxBot
  module Exchanges
    module Binance
      class DepthWs
        # Adapter around the `websocket-client-simple` gem (already a transitive
        # dependency via coindcx-client). Runs its own read thread, so callbacks
        # fire from a non-main thread — keep handlers cheap and thread-safe.
        class WebsocketClientSimpleTransport
          def initialize(logger: nil)
            @logger = logger
            @client = nil
          end

          def connect(url:, on_message:, on_open:, on_close:, on_error:)
            @client = WebSocket::Client::Simple.connect(url) do |client|
              client.on(:open) { on_open.call }
              client.on(:message) { |msg| on_message.call(msg.data) }
              client.on(:close) { |info| on_close.call(info) }
              client.on(:error) { |error| on_error.call(error) }
            end
            self
          end

          def close
            @client&.close
            @client = nil
            self
          end
        end
      end
    end
  end
end
