# frozen_string_literal: true

require 'spec_helper'
require_relative '../../../lib/coindcx_bot/dto/candle'

RSpec.describe CoindcxBot::Regime::MlRuntime do
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

  let(:fixture_path) { File.expand_path('../../fixtures/regime/ml_regime_constant_a.json', __dir__) }
  let(:model_tmp) { File.join(Dir.tmpdir, "ml_runtime_spec_model_#{Process.pid}.json") }

  let(:cfg) do
    CoindcxBot::Config.new(
      minimal_bot_config(
        regime: {
          enabled: true,
          ml: {
            enabled: true,
            model_path: model_tmp,
            scope: 'global',
            zscore_lookback: 30,
            confirm_bars: 2,
            immediate_probability: 0.99
          }
        }
      )
    )
  end

  before do
    File.binwrite(model_tmp, File.binread(fixture_path))
  end

  after do
    File.delete(model_tmp) if File.file?(model_tmp)
  end

  it 'exposes debounced ML state when candles are sufficient' do
    candles = 150.times.map { |i| candle(i, 100 + Math.sin(i / 10.0) * 2) }
    rt = described_class.new(config: cfg, logger: nil)
    rt.refresh!('B-SOL_USDT' => candles)
    st = rt.state_for('B-SOL_USDT')
    expect(st).not_to be_nil
    expect(st.label).to eq('a')
    expect(st.tier).to eq(:low_vol)
    expect(st.raw_label).to eq('a')
  end

  it 'clears state when the model file is missing' do
    File.delete(model_tmp)
    rt = described_class.new(config: cfg, logger: nil)
    candles = 150.times.map { |i| candle(i, 100 + Math.sin(i / 10.0) * 2) }
    rt.refresh!('B-SOL_USDT' => candles)
    expect(rt.state_for('B-SOL_USDT')).to be_nil
  end
end
