# frozen_string_literal: true

require 'tty-logger'
require_relative 'redactor'

module CoindcxBot
  module Logging
    # Thin wrapper over TTY::Logger that pipes every payload through Redactor
    # before it reaches the underlying handlers. Use this for any code path
    # that may carry API keys, signatures, or auth tokens.
    #
    # Usage:
    #   logger = CoindcxBot::Logging::Logger.build(component: 'gateway')
    #   logger.info('placed_order', client_order_id: 'abc', api_key: 'xxx')
    #     # => api_key value replaced with [REDACTED]
    class Logger
      LEVELS = %i[debug info warn error fatal].freeze

      def self.build(component: nil, output: $stdout, level: :info)
        new(
          TTY::Logger.new do |c|
            c.metadata = %i[time]
            c.output = output
            c.level = level
          end,
          component: component
        )
      end

      def initialize(inner, component: nil)
        @inner = inner
        @component = component
      end

      LEVELS.each do |lvl|
        define_method(lvl) do |event, payload = {}|
          emit(lvl, event, payload)
        end
      end

      private

      def emit(level, event, payload)
        safe = Redactor.call(payload || {})
        safe = safe.merge(component: @component) if @component
        @inner.public_send(level, event.to_s, safe)
      end
    end
  end
end
