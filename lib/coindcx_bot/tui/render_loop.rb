# frozen_string_literal: true

require 'stringio'

module CoindcxBot
  module Tui
    class RenderLoop
      DEFAULT_INTERVAL = 0.25
      QUEUE_POP_TIMEOUT = Gem::Version.new(RUBY_VERSION) >= Gem::Version.new('3.2')

      def initialize(panels:, interval: DEFAULT_INTERVAL, engine: nil, focus_sync_proc: nil)
        @panels    = panels
        @interval  = interval
        @engine    = engine
        @focus_sync_proc = focus_sync_proc
        @running   = false
        @thread    = nil
        @wake_queue = Queue.new
        @last_frames = {}
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

      def sync_tui_focus_to_engine!
        return unless @engine && @focus_sync_proc

        @engine.tui_focus_pair = @focus_sync_proc.call
      end

      def render_once
        sync_tui_focus_to_engine!
        @panels.each { |panel| render_panel_cached(panel) }
      rescue StandardError => e
        warn "[RenderLoop] #{e.class}: #{e.message}"
      end

      # Captures each panel’s ANSI frame off-terminal and skips stdout writes when nothing changed
      # (reduces flicker and syscall volume at idle).
      def render_panel_cached(panel)
        return panel.render unless panel.instance_variable_defined?(:@output)

        real_out = panel.instance_variable_get(:@output)
        buf = StringIO.new
        panel.instance_variable_set(:@output, buf)
        panel.render
        panel.instance_variable_set(:@output, real_out)
        frame = buf.string
        key = panel.object_id
        return if @last_frames[key] == frame

        @last_frames[key] = frame
        real_out.print(frame)
        real_out.flush
      rescue StandardError => e
        warn "[RenderLoop:panel] #{panel.class}: #{e.class}: #{e.message}"
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
