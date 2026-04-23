# frozen_string_literal: true

module CoindcxBot
  module Alerts
    # Suppresses repeated +analysis_price_cross+ emissions for the same pair and price rule
    # while LTP oscillates around a boundary (WS ticks).
    class PriceCrossCooldown
      def initialize
        @mutex = Mutex.new
        @last_emit_at = {}
      end

      # @return [Boolean] true if the caller should emit (and timestamp is updated); false if still cooling down
      def permit_emit?(pair:, rule_id:, cooldown_seconds:, now: Time.now)
        cd = Float(cooldown_seconds)
        return true if cd <= 0

        key = "#{pair.to_s}|#{rule_id.to_s}"
        @mutex.synchronize do
          prev = @last_emit_at[key]
          return false if prev && (now - prev) < cd

          @last_emit_at[key] = now
          true
        end
      rescue ArgumentError, TypeError
        true
      end
    end
  end
end
