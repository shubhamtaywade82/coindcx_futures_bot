# frozen_string_literal: true

module CoindcxBot
  module PaperExchange
    # Sliding windows: 16 requests per rolling second and 960 per rolling minute per API key.
    class RateLimit
      class Middleware
        def initialize(app, per_second: 16, per_minute: 960)
          @app = app
          @per_second = per_second
          @per_minute = per_minute
          @mutex = Mutex.new
          @windows = Hash.new { |h, k| h[k] = { sec: [], min: [] } }
        end

        def call(env)
          if env['REQUEST_METHOD'].to_s.upcase == 'GET' &&
             CoindcxBot::PaperExchange::Auth.normalized_request_path(env) == '/health'
            return @app.call(env)
          end
          return @app.call(env) if CoindcxBot::PaperExchange::Auth.public_market_get?(env)

          key = env['HTTP_X_AUTH_APIKEY'].to_s.strip
          key = 'anonymous' if key.empty?

          allowed, retry_after = @mutex.synchronize { allow?(key) }
          unless allowed
            return [
              429,
              {
                'Content-Type' => 'application/json',
                'Retry-After' => retry_after.ceil.to_s
              },
              [error_json('rate limit exceeded')]
            ]
          end

          @app.call(env)
        end

        private

        def allow?(key)
          now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          w = @windows[key]

          w[:sec].reject! { |t| now - t > 1.0 }
          w[:min].reject! { |t| now - t > 60.0 }

          if w[:sec].size >= @per_second
            return [false, 1.0 - (now - w[:sec].first)]
          end
          if w[:min].size >= @per_minute
            return [false, 60.0 - (now - w[:min].first)]
          end

          w[:sec] << now
          w[:min] << now
          [true, 0]
        end

        def error_json(message)
          require 'json'
          JSON.generate({ error: { message: message, code: 'rate_limit' } })
        end
      end
    end
  end
end
