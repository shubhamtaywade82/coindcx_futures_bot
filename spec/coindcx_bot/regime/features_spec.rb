# frozen_string_literal: true

require 'spec_helper'
require_relative '../../../lib/coindcx_bot/dto/candle'
require_relative '../../../lib/coindcx_bot/regime/features'

RSpec.describe CoindcxBot::Regime::Features do
  def candle(i, close)
    CoindcxBot::Dto::Candle.new(
      time: i,
      open: close * 0.999,
      high: close * 1.002,
      low: close * 0.998,
      close: close,
      volume: 1000 + i
    )
  end

  it 'produces indexed rows with bounded z-scores' do
    candles = 150.times.map { |i| candle(i, 100 + Math.sin(i / 10.0) * 2) }
    idx = described_class.indexed_rows(candles, zscore_lookback: 30)
    expect(idx).not_to be_empty
    expect(idx.last[:row].size).to eq(6)
    idx.each do |row|
      row[:row].each { |z| expect(z).to be_finite }
    end
  end
end
