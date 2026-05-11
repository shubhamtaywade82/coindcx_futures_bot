# frozen_string_literal: true

require 'bigdecimal'

RSpec.describe CoindcxBot::Orderflow::Engine, 'binance trade wiring' do
  let(:bus) { CoindcxBot::Core::EventBus.new }
  let(:config) do
    CoindcxBot::Config.new(
      minimal_bot_config(
        orderflow: {
          enabled: true,
          iceberg: { enabled: true },
          imbalance: { dedup: { enabled: false } },
          walls: { dedup: { enabled: false } }
        }
      )
    )
  end

  let(:engine) { described_class.new(bus: bus, config: config, logger: nil) }

  it 'routes binance-sourced trades to absorption_tracker and iceberg_detector' do
    absorption = engine.instance_variable_get(:@absorption)
    iceberg = engine.instance_variable_get(:@iceberg_detector)
    allow(absorption).to receive(:on_trade).and_call_original
    allow(iceberg).to receive(:on_trade).and_call_original

    trade = {
      pair: 'B-SOL_USDT',
      price: BigDecimal('150'),
      size: BigDecimal('0.5'),
      side: :buy,
      ts: 1_700_000_000_000,
      source: :binance
    }
    engine.on_trade(trade)

    expect(absorption).to have_received(:on_trade).with(hash_including(source: :binance, pair: 'B-SOL_USDT'))
    expect(iceberg).to have_received(:on_trade).with(hash_including(source: :binance))
  end
end
