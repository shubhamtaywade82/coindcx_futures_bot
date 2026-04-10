# frozen_string_literal: true

require 'spec_helper'
require 'coindcx_bot/paper_exchange'

RSpec.describe CoindcxBot::PaperExchange::Store do
  describe '.normalize_api_key' do
    it 'strips ASCII whitespace and a UTF-8 BOM' do
      raw = "\uFEFF  abc  ".dup.force_encoding(Encoding::UTF_8)
      expect(described_class.normalize_api_key(raw)).to eq('abc')
    end

    it 're-encodes BINARY env strings to UTF-8 for stable comparison' do
      raw = '3552deadbeef'.dup.force_encoding(Encoding::ASCII_8BIT)
      expect(described_class.normalize_api_key(raw)).to eq('3552deadbeef')
      expect(described_class.normalize_api_key(raw).encoding).to eq(Encoding::UTF_8)
    end
  end
end
