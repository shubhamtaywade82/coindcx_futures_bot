# frozen_string_literal: true

require 'spec_helper'
require 'coindcx_bot/logging/redactor'

RSpec.describe CoindcxBot::Logging::Redactor do
  describe '.call' do
    it 'redacts sensitive hash keys regardless of case' do
      input = { api_key: 'k', 'API_SECRET' => 's', X_AUTH_SIGNATURE: 'sig', safe: 'ok' }

      result = described_class.call(input)

      expect(result[:api_key]).to eq('[REDACTED]')
      expect(result['API_SECRET']).to eq('[REDACTED]')
      expect(result[:X_AUTH_SIGNATURE]).to eq('[REDACTED]')
      expect(result[:safe]).to eq('ok')
    end

    it 'redacts nested structures' do
      input = { headers: { 'Authorization' => 'Bearer xyz' }, body: [{ token: 't' }] }

      result = described_class.call(input)

      expect(result[:headers]['Authorization']).to eq('[REDACTED]')
      expect(result[:body].first[:token]).to eq('[REDACTED]')
    end

    it 'redacts HMAC-style hex signatures embedded in strings' do
      sig = 'a' * 64
      input = "signed=#{sig} extra"

      expect(described_class.call(input)).to eq('signed=[REDACTED] extra')
    end

    it 'leaves non-sensitive primitives untouched' do
      expect(described_class.call(42)).to eq(42)
      expect(described_class.call('hello')).to eq('hello')
      expect(described_class.call(nil)).to be_nil
    end

    it 'redacts password and passphrase keys' do
      input = { password: 'p', 'passphrase' => 'q' }

      result = described_class.call(input)

      expect(result[:password]).to eq('[REDACTED]')
      expect(result['passphrase']).to eq('[REDACTED]')
    end
  end
end
