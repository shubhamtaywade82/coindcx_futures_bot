# frozen_string_literal: true

module CoindcxBot
  module Tui
    class RenderLoop
      DEFAULT_INTERVAL = 0.25
      QUEUE_POP_TIMEOUT = Gem::Version.new(RUBY_VERSION) >= Gem::Version.new('3.2')

      def initialize(panels:, interval: DEFAULT_INTERVAL)
        @panels    = panels
        @interval  = interval
        @running   = false
        @thread    = nil
        @wake_queue = Queue.new
      end

      def start
        @running = true
        @thread  = Thread.new do
          Thread.current.name = 'tui-render'
          Thread.current.abort_on_exception = false

          while @running
            render_once
            wait_for_tick_or_interval
          end
        end
      end

      # Thread-safe: call from the WebSocket thread (or any thread) to repaint as soon as the current
      # frame finishes — avoids waiting the full idle interval when prices change.
      def request_redraw
        return unless @running

        @wake_queue.push(:tick)
      rescue ClosedQueueError
        # shutting down
      end

      def stop
        @running = false
        begin
          @wake_queue.push(:stop)
        rescue ClosedQueueError
          nil
        end
        @thread&.join(2)
      end

      def running?
        @running && @thread&.alive?
      end

      private

      def render_once
        @panels.each(&:render)
      rescue StandardError => e
        warn "[RenderLoop] #{e.class}: #{e.message}"
      end

      def wait_for_tick_or_interval
        return unless @running

        if QUEUE_POP_TIMEOUT
          @wake_queue.pop(timeout: @interval)
        else
          wait_for_tick_or_interval_poll
        end
        drain_wake_queue
      end

      def drain_wake_queue
        loop do
          @wake_queue.pop(true)
        rescue ThreadError
          break
        end
      end

      def wait_for_tick_or_interval_poll
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @interval
        loop do
          return if wake_queue_pop_non_block

          break unless @running
          remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          break if remaining <= 0

          sleep [remaining, 0.05].min
        end
      end

      def wake_queue_pop_non_block
        @wake_queue.pop(true)
      rescue ThreadError
        nil
      end
    end
  end
end
