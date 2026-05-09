# frozen_string_literal: true

module CoindcxBot
  module Persistence
    # Persists the last successful Ollama call timestamp per brain in the journal `meta` table
    # so a process restart does not bypass the in-memory throttle window in Engine.
    class AiThrottleStore
      REGIME_AI_KEY = 'ai_throttle:regime_ai_updated_at'
      SMC_PLANNER_KEY = 'ai_throttle:smc_planner_updated_at'

      def initialize(journal)
        @journal = journal
      end

      def regime_ai_updated_at
        read_time(REGIME_AI_KEY)
      end

      def write_regime_ai_updated_at(time)
        write_time(REGIME_AI_KEY, time)
      end

      def smc_planner_updated_at
        read_time(SMC_PLANNER_KEY)
      end

      def write_smc_planner_updated_at(time)
        write_time(SMC_PLANNER_KEY, time)
      end

      private

      def read_time(key)
        raw = @journal.meta_get(key)
        return nil if raw.nil? || raw.to_s.strip.empty?

        Time.at(Float(raw))
      rescue ArgumentError, TypeError
        nil
      end

      def write_time(key, time)
        return if time.nil?

        @journal.meta_set(key, time.to_f.to_s)
      end
    end
  end
end
