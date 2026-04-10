# frozen_string_literal: true

require 'openssl'
require 'json'
require 'stringio'

module CoindcxBot
  module PaperExchange
    # Verifies CoinDCX HMAC (same contract as CoinDCX::Auth::Signer).
    module Auth
      module_function

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

          api_key = env['HTTP_X_AUTH_APIKEY'].to_s
          sig_header = env['HTTP_X_AUTH_SIGNATURE'].to_s
          return error_response(401, 'missing auth headers') if api_key.empty? || sig_header.empty?

          row = @store.db.get_first_row(
            'SELECT user_id, api_secret FROM pe_api_keys WHERE api_key = ?',
            [api_key]
          )
          return error_response(401, 'unknown api key') unless row

          expected = Auth.verify_signature!(raw, row['api_secret'])
          return error_response(401, 'invalid signature') unless secure_compare(expected, sig_header)

          env['paper_exchange.user_id'] = row['user_id'].to_i
          env['paper_exchange.raw_body'] = raw
          env['paper_exchange.parsed_body'] =
            raw.empty? ? {} : JSON.parse(raw)

          @app.call(env)
        rescue JSON::ParserError
          error_response(400, 'invalid json')
        end

        private

        def skip_auth?(env)
          env['PATH_INFO'].to_s == '/health'
        end

        def secure_compare(a, b)
          return false if a.bytesize != b.bytesize

          OpenSSL.fixed_length_secure_compare(a, b)
        rescue ArgumentError
          false
        end

        def error_response(status, message)
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
