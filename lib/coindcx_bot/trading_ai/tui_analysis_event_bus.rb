# frozen_string_literal: true

module CoindcxBot
  module TradingAi
    # Thread-safe event bus that buffers TUI AI analysis trigger events
    # (e.g. SMC setup transitions, structure shifts, regime flips, position
    # lifecycle changes). Drained when the brain runs; oldest events are
    # dropped past `max_size` so the bus never grows unbounded.
    class TuiAnalysisEventBus
      DEFAULT_MAX_SIZE = 100

      KNOWN_TYPES = %i[
        smc_setup_new
        smc_setup_invalidated
        smc_setup_filled
        sweep_confirmed
        ob_tap
        bos
        choch
        breakout
        breakdown
        regime_flip
        position_open
        position_close
        sl_hit
        tp_hit
        partial_fill
        signal_flip
      ].freeze

      def initialize(max_size: DEFAULT_MAX_SIZE)
        @max_size = max_size.to_i.positive? ? max_size.to_i : DEFAULT_MAX_SIZE
        @mutex = Mutex.new
        @events = []
      end

      def record(type, payload = {}, occurred_at: Time.now)
        ev = { type: type.to_sym, payload: payload.is_a?(Hash) ? payload : {}, at: occurred_at }
        @mutex.synchronize do
          @events << ev
          @events.shift while @events.size > @max_size
        end
        ev
      end

      def pending?
        @mutex.synchronize { !@events.empty? }
      end

      def size
        @mutex.synchronize { @events.size }
      end

      def drain
        @mutex.synchronize do
          drained = @events
          @events = []
          drained
        end
      end

      def peek
        @mutex.synchronize { @events.dup }
      end

      def clear!
        @mutex.synchronize { @events.clear }
      end
    end
  end
end
