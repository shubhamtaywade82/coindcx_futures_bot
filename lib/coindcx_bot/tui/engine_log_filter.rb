# frozen_string_literal: true

module CoindcxBot
  module Tui
    # Drops the noisiest CoinDCX structured events when COINDCX_TUI_VERBOSE=1 writes to tmp/coindcx_tui.log.
    class EngineLogFilter
      def initialize(inner)
        @inner = inner
      end

      def info(payload)
        return if verbose_events? && suppress_info?(payload)

        @inner.info(payload)
      end

      def warn(payload)
        return if verbose_events? && suppress_warn?(payload)

        @inner.warn(payload)
      end

      def error(payload)
        @inner.error(payload)
      end

      def debug(payload)
        @inner.debug(payload)
      end

      def respond_to_missing?(name, include_private = false)
        @inner.respond_to?(name, include_private) || super
      end

      def method_missing(name, *args, &block)
        @inner.public_send(name, *args, &block)
      end

      private

      def verbose_events?
        ENV['COINDCX_TUI_LOG_ALL'].to_s != '1'
      end

      def suppress_info?(payload)
        return false unless payload.is_a?(Hash)

        event = payload[:event] || payload['event']
        return false unless event == 'api_call'

        status = payload[:response_status] || payload['response_status']
        status.to_i == 200
      end

      def suppress_warn?(payload)
        return false unless payload.is_a?(Hash)

        (payload[:event] || payload['event']) == 'ws_disconnected'
      end
    end
  end
end
