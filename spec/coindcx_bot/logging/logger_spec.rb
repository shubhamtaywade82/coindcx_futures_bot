# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'coindcx_bot/logging/logger'

RSpec.describe CoindcxBot::Logging::Logger do
  let(:output) { StringIO.new }

  describe '.build + #info' do
    it 'redacts sensitive fields in payload before writing' do
      logger = described_class.build(component: 'gateway', output: output, level: :debug)

      logger.info('order_placed', api_key: 'leak', client_order_id: 'abc')

      written = output.string
      expect(written).not_to include('leak')
      expect(written).to include('[REDACTED]')
      expect(written).to include('order_placed')
      expect(written).to include('abc')
    end

    it 'tags payload with component metadata' do
      logger = described_class.build(component: 'gateway', output: output, level: :debug)

      logger.warn('slow_request')

      expect(output.string).to include('gateway')
    end

    it 'redacts HMAC signatures embedded in string payload values' do
      logger = described_class.build(output: output, level: :debug)
      sig = 'b' * 64

      logger.error('signed_request', body: "sig=#{sig}")

      expect(output.string).not_to include(sig)
      expect(output.string).to include('[REDACTED]')
    end
  end
end
