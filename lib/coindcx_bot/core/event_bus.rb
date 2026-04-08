# frozen_string_literal: true

module CoindcxBot
  module Core
    class EventBus
      def initialize
        @listeners = Hash.new { |h, k| h[k] = [] }
        @mutex = Mutex.new
      end

      def subscribe(event, &block)
        @mutex.synchronize { @listeners[event] << block }
        self
      end

      def publish(event, payload = nil)
        listeners = @mutex.synchronize { @listeners[event].dup }
        listeners.each { |listener| listener.call(payload) }
        self
      end

      def clear!
        @mutex.synchronize { @listeners.clear }
      end
    end
  end
end
