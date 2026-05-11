# frozen_string_literal: true

module CoindcxBot
  module Risk
    # Thread-safe {pair => DivergenceGuard} populated when the Binance shadow stack boots.
    class GuardRegistry
      def initialize
        @mutex = Mutex.new
        @guards = {}
      end

      def register(pair:, guard:)
        sym = pair.to_s
        @mutex.synchronize { @guards[sym] = guard }
        self
      end

      def for(pair:)
        sym = pair.to_s
        @mutex.synchronize { @guards[sym] }
      end

      def pairs
        @mutex.synchronize { @guards.keys.dup }
      end

      def clear!
        @mutex.synchronize { @guards.clear }
        self
      end
    end
  end
end
