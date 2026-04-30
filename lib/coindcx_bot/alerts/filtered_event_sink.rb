# frozen_string_literal: true

module CoindcxBot
  module Alerts
    # Wraps a sink (e.g. TelegramJournalSink) and drops deliveries that fail {TelegramPolicy#permit?}.
    class FilteredEventSink
      def initialize(inner, policy)
        @inner = inner
        @policy = policy
      end

      def deliver(type, payload)
        return unless @inner&.respond_to?(:deliver)
        return unless @policy.permit?(type, payload)

        @inner.deliver(type, payload)
      end
    end
  end
end
