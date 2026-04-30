# frozen_string_literal: true

require 'thread'

module CoindcxBot
  module Alerts
    # Throttle + optional allowlist for Telegram delivery (journal rows are always persisted).
    class TelegramPolicy
      def initialize(config)
        @config = config
        @mutex = Mutex.new
        @last_deliver_at = {}
      end

      def permit?(type, payload, now = Time.now)
        return true unless @config.alerts_filter_telegram?

        t = type.to_s
        return false unless type_allowed?(t)

        throttle_s = throttle_seconds_for(t)
        return true if throttle_s <= 0

        key = dedupe_key(t, payload)
        @mutex.synchronize do
          prev = @last_deliver_at[key]
          return false if prev && (now - prev) < throttle_s

          @last_deliver_at[key] = now
        end
        true
      end

      private

      def type_allowed?(type)
        allow = @config.alerts_telegram_allow_types
        return true if allow.nil? || allow.empty?

        crit = @config.alerts_telegram_critical_types
        return true if crit.include?(type)

        allow.any? { |pat| pattern_match?(pat, type) }
      end

      def pattern_match?(pattern, type)
        p = pattern.to_s
        return true if p == type
        return type.start_with?(p.chomp('*')) if p.end_with?('*') && p.length > 1

        false
      end

      def throttle_seconds_for(type)
        by = @config.alerts_telegram_throttle_by_type
        return Float(by[type]) if by.key?(type)

        if @config.alerts_telegram_critical_types.include?(type)
          return @config.alerts_telegram_critical_throttle_seconds
        end

        @config.alerts_telegram_default_throttle_seconds
      rescue ArgumentError, TypeError
        0.0
      end

      def dedupe_key(type, payload)
        h = payload.is_a?(Hash) ? payload.transform_keys(&:to_sym) : {}
        pair = (h[:pair] || h['pair']).to_s
        extra = (h[:dedupe_key] || h['dedupe_key']).to_s
        extra = 'default' if extra.empty?
        "#{type}:#{pair}:#{extra}"
      end
    end
  end
end
