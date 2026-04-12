# frozen_string_literal: true

require 'json'
require 'bigdecimal'
require 'faraday'

module CoindcxBot
  module PaperExchange
    # Proxies CoinDCX futures conversions (USDT/INR) with TTL cache; falls back to a synthetic row.
    class ConversionsFeed
      DEFAULT_HOST = 'https://api.coindcx.com'
      DEFAULT_PATH = '/api/v1/derivatives/futures/data/conversions'

      def initialize(fallback_inr_per_usdt:, ttl_seconds:, logger:,
                     api_host: DEFAULT_HOST, path: DEFAULT_PATH, faraday: nil, clock: nil)
        @fallback = BigDecimal(fallback_inr_per_usdt.to_s)
        @ttl = [ttl_seconds.to_i, 5].max
        @logger = logger
        @path = path.to_s.start_with?('/') ? path.to_s : "/#{path}"
        host = api_host.to_s.chomp('/')
        @conn = faraday || Faraday.new(url: host) do |f|
          f.options.open_timeout = 5
          f.options.timeout = 10
        end
        @clock = clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
        @mutex = Mutex.new
        @cached = nil
        @cached_at = nil
      end

      def fetch_json_array
        @mutex.synchronize do
          now = @clock.call
          if @cached && @cached_at && (now - @cached_at) < @ttl
            return @cached
          end

          body = pull_upstream
          if body.is_a?(Array) && body.any? &&
             CoindcxBot::Fx::UsdtInrRate.inr_per_usdt_from_conversions_body(body)
            @cached = body
          else
            @cached = [synthetic_row(@fallback)]
          end
          @cached_at = now
          @cached
        end
      end

      private

      def pull_upstream
        resp = @conn.get(@path) do |req|
          req.headers['Accept'] = 'application/json'
        end
        return nil unless resp.status == 200

        JSON.parse(resp.body)
      rescue StandardError => e
        @logger&.warn("[paper_exchange] conversions upstream: #{e.class}: #{e.message}")
        nil
      end

      def synthetic_row(price_bd)
        now_ms = (Time.now.utc.to_f * 1000).to_i
        {
          'symbol' => 'USDTINR',
          'margin_currency_short_name' => 'INR',
          'target_currency_short_name' => 'USDT',
          'conversion_price' => price_bd.to_f,
          'last_updated_at' => now_ms
        }
      end
    end
  end
end
