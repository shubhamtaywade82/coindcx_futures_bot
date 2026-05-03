# frozen_string_literal: true

module CoindcxBot
  module Logging
    # Redacts secrets from log payloads before they leave the process.
    # Sensitive keys are matched case-insensitively against a deny list;
    # values are replaced with REDACTED. Recurses through Hash and Array.
    module Redactor
      REDACTED = '[REDACTED]'

      SENSITIVE_KEY_PATTERNS = [
        /api[_-]?key/i,
        /api[_-]?secret/i,
        /\Asecret\z/i,
        /\Atoken\z/i,
        /access[_-]?token/i,
        /refresh[_-]?token/i,
        /authorization/i,
        /x[_-]auth[_-]apikey/i,
        /x[_-]auth[_-]signature/i,
        /password/i,
        /passphrase/i,
        /bearer/i,
        /signature/i,
      ].freeze

      # HMAC-SHA256 hex (64 chars) — common shape for CoinDCX X-AUTH-SIGNATURE.
      HEX_SIGNATURE_PATTERN = /\b[a-f0-9]{64,}\b/i

      module_function

      def call(value)
        case value
        when Hash  then redact_hash(value)
        when Array then value.map { |v| call(v) }
        when String then redact_string(value)
        else value
        end
      end

      def sensitive_key?(key)
        str = key.to_s
        SENSITIVE_KEY_PATTERNS.any? { |re| str.match?(re) }
      end

      def redact_hash(hash)
        hash.each_with_object({}) do |(k, v), memo|
          memo[k] = sensitive_key?(k) ? REDACTED : call(v)
        end
      end

      def redact_string(str)
        str.gsub(HEX_SIGNATURE_PATTERN, REDACTED)
      end
    end
  end
end
