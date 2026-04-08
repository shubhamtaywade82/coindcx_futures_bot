# frozen_string_literal: true

module CoindcxBot
  module Tui
    class RenderLoop
      DEFAULT_INTERVAL = 0.25

      def initialize(panels:, interval: DEFAULT_INTERVAL)
        @panels   = panels
        @interval = interval
        @running  = false
        @thread   = nil
      end

      def start
        @running = true
        @thread  = Thread.new do
          Thread.current.name = 'tui-render'
          Thread.current.abort_on_exception = false

          render_cycle while @running
        end
      end

      def stop
        @running = false
        @thread&.join(2)
      end

      def running?
        @running && @thread&.alive?
      end

      private

      def render_cycle
        @panels.each(&:render)
      rescue StandardError => e
        warn "[RenderLoop] #{e.class}: #{e.message}"
      ensure
        sleep @interval
      end
    end
  end
end
