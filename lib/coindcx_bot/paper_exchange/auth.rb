# frozen_string_literal: true

require 'openssl'
require 'json'
require 'stringio'
require 'rack/request'

module CoindcxBot
  module PaperExchange
    # Verifies CoinDCX HMAC (same contract as CoinDCX::Auth::Signer).
    module Auth
      module_function

      # CoinDCX::REST::Futures::MarketData uses `auth: false` for these GETs — no X-AUTH headers on the wire.
      PUBLIC_MARKET_GET_PATHS = %w[
        /exchange/v1/derivatives/futures/data/instrument
        /exchange/v1/derivatives/futures/data/active_instruments
        /exchange/v1/derivatives/futures/data/trades
        /api/v1/derivatives/futures/data/stats
        /api/v1/derivatives/futures/data/conversions
      ].freeze

      def normalized_request_path(env)
        Rack::Request.new(env).path.to_s.sub(%r{\A//+}, '/').chomp('/')
      end

      def public_market_get?(env)
        return false unless env['REQUEST_METHOD'].to_s.upcase == 'GET'

        req_path = normalized_request_path(env)
        PUBLIC_MARKET_GET_PATHS.any? { |p| p.chomp('/') == req_path }
      end

      def verify_signature!(raw_body, api_secret)
        require 'coindcx'
        parsed = JSON.parse(raw_body)
        normalized = CoinDCX::Utils::Payload.compact_hash(parsed)
        normalized = normalized.transform_keys(&:to_sym)
        payload = JSON.generate(CoinDCX::Utils::Payload.stringify_keys(normalized))
        signature = OpenSSL::HMAC.hexdigest('SHA256', api_secret, payload)
        signature
      end

      class Middleware
        def initialize(app, store:)
          @app = app
          @store = store
        end

        def call(env)
          return @app.call(env) if skip_auth?(env)

          raw = env['rack.input'].read
          env['rack.input'] = StringIO.new(raw)

          api_key = env['HTTP_X_AUTH_APIKEY'].to_s.strip
          sig_header = env['HTTP_X_AUTH_SIGNATURE'].to_s.strip
          return error_response(env, 401, 'missing auth headers') if api_key.empty? || sig_header.empty?

          row = @store.db.get_first_row(
            'SELECT user_id, api_secret FROM pe_api_keys WHERE TRIM(api_key) = ?',
            [api_key]
          )
          return error_response(env, 401, 'unknown api key') unless row

          expected = Auth.verify_signature!(raw, row['api_secret'])
          return error_response(env, 401, 'invalid signature') unless secure_compare(expected, sig_header)

          env['paper_exchange.user_id'] = row['user_id'].to_i
          env['paper_exchange.raw_body'] = raw
          env['paper_exchange.parsed_body'] =
            raw.empty? ? {} : JSON.parse(raw)

          @app.call(env)
        rescue JSON::ParserError
          error_response(env, 400, 'invalid json')
        end

        private

        def skip_auth?(env)
          return true if env['REQUEST_METHOD'].to_s.upcase == 'GET' && Auth.normalized_request_path(env) == '/health'

          Auth.public_market_get?(env)
        end

        def secure_compare(a, b)
          return false if a.bytesize != b.bytesize

          OpenSSL.fixed_length_secure_compare(a, b)
        rescue ArgumentError
          false
        end

        def error_response(env, status, message)
          if ENV['PAPER_EXCHANGE_AUTH_DEBUG'].to_s == '1'
            meth = env['REQUEST_METHOD'].to_s.upcase
            path = Auth.normalized_request_path(env)
            warn("[paper_exchange:auth] #{status} #{meth} #{path} — #{message}")
          end
          [
            status,
            { 'Content-Type' => 'application/json' },
            [JSON.generate({ error: { message: message, code: 'auth_error' } })]
          ]
        end
      end
    end
  end
end
