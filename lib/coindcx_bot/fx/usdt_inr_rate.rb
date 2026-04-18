# frozen_string_literal: true

require 'bigdecimal'

module CoindcxBot
  module Fx
    # Cached INR per 1 USDT from CoinDCX futures GET /api/v1/derivatives/futures/data/conversions.
    class UsdtInrRate
      def initialize(client:, config:, logger: nil, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
        @client = client
        @config = config
        @logger = logger
        @clock = clock
        @mutex = Mutex.new
        @cached_value = nil
        @cached_at = nil
      end

      def inr_per_usdt
        @mutex.synchronize do
          refresh_locked_if_stale!
          effective_value_locked
        end
      end

      def refresh_if_stale!
        @mutex.synchronize { refresh_locked_if_stale! }
      end

      def self.inr_per_usdt_from_conversions_body(body)
        rows =
          case body
          when Array then body
          else
            []
          end
        row = rows.find { |r| row_matches_usdt_inr?(r) }
        return nil unless row

        price = row[:conversion_price] || row['conversion_price']
        bd = BigDecimal(price.to_s)
        bd.positive? ? bd : nil
      rescue ArgumentError, TypeError
        nil
      end

      def self.row_matches_usdt_inr?(r)
        return false unless r.is_a?(Hash)

        sym = (r[:symbol] || r['symbol']).to_s
        return true if sym.casecmp('USDTINR').zero?

        margin = (r[:margin_currency_short_name] || r['margin_currency_short_name']).to_s
        target = (r[:target_currency_short_name] || r['target_currency_short_name']).to_s
        margin.casecmp('INR').zero? && target.casecmp('USDT').zero?
      end

      private

      def refresh_locked_if_stale!
        return unless @config.fx_enabled?

        now = @clock.call
        ttl = @config.fx_ttl_seconds
        return if @cached_at && (now - @cached_at) < ttl

        fetch_and_cache_locked!(now)
      end

      def fetch_and_cache_locked!(now)
        raw = @client.futures.market_data.conversions
        parsed = self.class.inr_per_usdt_from_conversions_body(raw)
        if parsed
          @cached_value = parsed
          @cached_at = now
          return
        end

        # Don't update @cached_at on empty/invalid response so next call retries immediately.
        @logger&.warn('[fx] conversions response missing USDTINR conversion_price — using fallback or last good')
      rescue StandardError => e
        # Don't update @cached_at on fetch error so next call retries immediately.
        @logger&.warn("[fx] conversions fetch failed: #{e.class}: #{e.message}")
      end

      def effective_value_locked
        return @config.inr_per_usdt unless @config.fx_enabled?

        @cached_value || @config.inr_per_usdt
      end
    end
  end
end
