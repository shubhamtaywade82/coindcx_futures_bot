# frozen_string_literal: true

require 'bigdecimal'

RSpec.describe CoindcxBot::Orderflow::LiquidityZoneTracker do
  let(:bus) { CoindcxBot::Core::EventBus.new }
  let(:captured) { [] }

  let(:config) do
    double(
      orderflow_section: {
        zones: {
          enabled: true,
          band_ticks: 5,
          min_persistence_ms: 25,
          expiry_ms: 60_000,
          tick_size: '0.01'
        }
      }
    )
  end

  before { bus.subscribe(:'liquidity.zone.confirmed') { |e| captured << e } }

  it 'confirms a zone after wall touches span min persistence' do
    described_class.new(bus: bus, config: config)
    bus.publish(
      :'liquidity.wall.detected',
      { pair: 'P', symbol: 'P', source: :binance, side: :bid, price: BigDecimal('100'), score: 1, ts: 0 }
    )
    bus.publish(
      :'liquidity.wall.detected',
      { pair: 'P', symbol: 'P', source: :binance, side: :bid, price: BigDecimal('100'), score: 1, ts: 30 }
    )

    expect(captured.size).to eq(1)
    expect(captured.first[:touch_count]).to eq(2)
    expect(captured.first[:source]).to eq(:binance)
  end

  it 'does not confirm when walls are too far apart in time' do
    described_class.new(bus: bus, config: config)
    bus.publish(
      :'liquidity.wall.detected',
      { pair: 'P', symbol: 'P', source: :binance, side: :ask, price: BigDecimal('50'), score: 1, ts: 0 }
    )
    bus.publish(
      :'liquidity.wall.detected',
      { pair: 'P', symbol: 'P', source: :binance, side: :ask, price: BigDecimal('50'), score: 1, ts: 10 }
    )
    expect(captured).to be_empty
  end
end
