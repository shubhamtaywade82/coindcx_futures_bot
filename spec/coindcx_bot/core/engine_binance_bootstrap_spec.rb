# frozen_string_literal: true

require 'logger'

RSpec.describe CoindcxBot::Core::Engine, 'binance orderflow stack' do
  around do |example|
    prev_key = ENV['COINDCX_API_KEY']
    prev_sec = ENV['COINDCX_API_SECRET']
    ENV['COINDCX_API_KEY'] = 'test_key'
    ENV['COINDCX_API_SECRET'] = 'test_secret'
    CoinDCX.reset_configuration!
    example.run
  ensure
    prev_key.nil? ? ENV.delete('COINDCX_API_KEY') : ENV['COINDCX_API_KEY'] = prev_key
    prev_sec.nil? ? ENV.delete('COINDCX_API_SECRET') : ENV['COINDCX_API_SECRET'] = prev_sec
    CoinDCX.reset_configuration!
  end

  let(:logger) { Logger.new(File::NULL) }

  let(:config) do
    CoindcxBot::Config.new(
      minimal_bot_config(
        orderflow: {
          enabled: true,
          binance: {
            enabled: true,
            symbols: { 'SOLUSDT' => 'B-SOL_USDT' }
          }
        }
      )
    )
  end

  it 'stop_binance_orderflow_stacks! invokes stop on adapters and monitors and clears guard' do
    adapter = instance_double(CoindcxBot::Orderflow::BinanceAdapter, stop: nil)
    monitor = instance_double(
      CoindcxBot::MarketData::DivergenceMonitor,
      stop: nil,
      snapshot: { pair: 'B-SOL_USDT', status: :ok, bps: nil, age_ms: nil, reason: nil }
    )
    engine = described_class.new(config: config, logger: logger)
    engine.instance_variable_set(:@binance_adapters, [adapter])
    engine.instance_variable_set(:@binance_monitors, [monitor])
    engine.instance_variable_set(:@binance_divergence_guard, CoindcxBot::Risk::DivergenceGuard.new(max_bps: 25, max_lag_ms: 1_500))

    engine.send(:stop_binance_orderflow_stacks!)

    expect(adapter).to have_received(:stop)
    expect(monitor).to have_received(:stop)
    expect(engine.instance_variable_get(:@binance_adapters)).to eq([])
    expect(engine.instance_variable_get(:@binance_monitors)).to eq([])
    expect(engine.instance_variable_get(:@binance_divergence_guard)).to be_nil
  end
end
