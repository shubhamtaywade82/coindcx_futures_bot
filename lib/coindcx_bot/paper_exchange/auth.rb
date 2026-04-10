# frozen_string_literal: true

require 'digest'
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

      # Short, non-reversible fingerprint for comparing client vs server .env (SHA-256 prefix + byte length).
      def key_fingerprint(api_key)
        k = Store.normalize_api_key(api_key)
        return 'empty' if k.empty?

        "#{Digest::SHA256.hexdigest(k)[0, 10]}…(len=#{k.bytesize})"
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

          api_key = Store.normalize_api_key(env['HTTP_X_AUTH_APIKEY'])
          sig_header = env['HTTP_X_AUTH_SIGNATURE'].to_s.strip
          return error_response(env, 401, 'missing auth headers') if api_key.empty? || sig_header.empty?

          row = lookup_api_key_row(api_key)
          unless row
            try_resync_pe_api_key_row!(api_key)
            row = lookup_api_key_row(api_key)
          end
          unless row
            log_auth_debug_unknown(api_key) if ENV['PAPER_EXCHANGE_AUTH_DEBUG'].to_s == '1'
            return error_response(
              env,
              401,
              'unknown api key',
              hint: unknown_api_key_hint(api_key)
            )
          end

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

        def error_response(env, status, message, hint: nil)
          meth = env['REQUEST_METHOD'].to_s.upcase
          req_path = Auth.normalized_request_path(env)
          code = auth_error_code(status, message)
          log_auth_failure(status, meth, req_path, message, code, hint)
          err = { message: message, code: code }
          err[:hint] = hint if hint
          [
            status,
            { 'Content-Type' => 'application/json' },
            [JSON.generate({ error: err })]
          ]
        end

        def lookup_api_key_row(api_key)
          rows = @store.db.execute('SELECT user_id, api_secret, api_key FROM pe_api_keys')
          hit = rows.find { |h| Store.normalize_api_key(h['api_key']) == api_key }
          return nil unless hit

          { 'user_id' => hit['user_id'], 'api_secret' => hit['api_secret'] }
        end

        # Re-run Boot seed when the HTTP key matches this process's COINDCX_API_KEY but the row is missing
        # (wiped table, hand-edited DB, or rare startup ordering). No-op when keys differ.
        def try_resync_pe_api_key_row!(request_api_key)
          srv_key = Store.normalize_api_key(ENV.fetch('COINDCX_API_KEY', ''))
          srv_secret = ENV.fetch('COINDCX_API_SECRET', '').to_s.strip
          return false if srv_key.empty? || srv_secret.empty?
          return false unless request_api_key == srv_key

          Boot.ensure_seed!(@store, api_key: srv_key, api_secret: srv_secret)
          true
        rescue StandardError => e
          warn("[paper_exchange:auth] re-seed failed: #{e.class}: #{e.message}")
          false
        end

        def log_auth_debug_unknown(request_api_key)
          srv_key = Store.normalize_api_key(ENV['COINDCX_API_KEY'])
          warn(
            "[paper_exchange:auth:debug] db=#{@store.db_path} req==env? #{request_api_key == srv_key} " \
            "fp_req=#{Auth.key_fingerprint(request_api_key)} fp_env=#{Auth.key_fingerprint(srv_key)}"
          )
        end

        def unknown_api_key_hint(request_api_key)
          srv_key = Store.normalize_api_key(ENV.fetch('COINDCX_API_KEY', ''))
          req_fp = Auth.key_fingerprint(request_api_key)
          srv_fp = Auth.key_fingerprint(srv_key)
          db = @store.db_path
          if srv_key.empty?
            'paper-exchange process has empty COINDCX_API_KEY'
          elsif req_fp != srv_fp
            "request key #{req_fp} != server env #{srv_fp}; use identical COINDCX_* in both processes " \
            '(shell exports override repo .env — run `unset COINDCX_API_KEY COINDCX_API_SECRET` or use a clean terminal)'
          else
            "request matches server env but no DB row in #{db} after re-seed — stop server, delete that file, restart"
          end
        end

        def auth_error_code(status, message)
          return 'invalid_json' if status == 400 && message == 'invalid json'

          case message
          when 'missing auth headers' then 'missing_auth_headers'
          when 'unknown api key' then 'unknown_api_key'
          when 'invalid signature' then 'invalid_signature'
          else 'auth_error'
          end
        end

        def log_auth_failure(status, meth, req_path, message, code, hint = nil)
          line = "[paper_exchange:auth] #{status} #{meth} #{req_path} — #{message} (code=#{code})"
          line = "#{line} — #{hint}" if hint
          warn(line)
        end
      end
    end
  end
end
