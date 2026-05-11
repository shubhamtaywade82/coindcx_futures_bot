# frozen_string_literal: true

require 'logger'

RSpec.describe CoindcxBot::Orderflow::LiquidityContextStore do
  let(:bus) { CoindcxBot::Core::EventBus.new }
  let(:t0) { 1_700_000_000_000 }
  let(:clock_ms) { { value: t0 } }
  let(:clock) { -> { clock_ms[:value] } }
  let(:store) do
    described_class.new(
      bus: bus,
      clock: clock,
      divergence_lookup: lambda { |_pair|
        { pair: 'B-SOL_USDT', status: :ok, bps: BigDecimal('1.2'), age_ms: 50, reason: nil }
      }
    )
  end

  let(:pair) { 'B-SOL_USDT' }

  before { store }

  it 'ignores CoinDCX-sourced imbalance events' do
    bus.publish(:orderflow_imbalance, { pair: pair, value: 0.5, bias: :bullish, depth: 5, source: :coindcx, ts: t0 })
    snap = store.snapshot(pair)
    expect(snap[:imbalance]).to be_nil
    expect(snap[:last_touch_ms]).to be_nil
  end

  it 'records Binance imbalance' do
    bus.publish(:orderflow_imbalance, { pair: pair, value: 0.42, bias: :bearish, depth: 5, source: :binance, ts: t0 })
    snap = store.snapshot(pair)
    expect(snap[:imbalance][:bucket]).to eq(:bearish)
    expect(snap[:imbalance][:value]).to eq(BigDecimal('0.42'))
    expect(snap[:last_touch_ms]).to eq(t0)
  end

  it 'maintains active walls and prunes by age using clock' do
    bus.publish(
      :'liquidity.wall.detected',
      { pair: pair, source: :binance, side: :ask, price: '101', size: '12', score: 2.0, ts: t0, price_band: '101' }
    )
    snap1 = store.snapshot(pair)
    expect(snap1[:active_walls][:ask].size).to eq(1)
    expect(snap1[:active_walls][:ask].first[:score]).to eq(BigDecimal('2.0'))

    clock_ms[:value] = t0 + 61_000

    snap2 = store.snapshot(pair)
    expect(snap2[:active_walls][:ask]).to be_empty
  end

  it 'removes wall on wall.removed' do
    bus.publish(
      :'liquidity.wall.detected',
      { pair: pair, source: :binance, side: :bid, price: '99', size: '5', score: 1.2, ts: t0, price_band: '99' }
    )
    bus.publish(
      :'liquidity.wall.removed',
      { pair: pair, source: :binance, side: :bid, price: '99', price_band: '99', ts: t0 + 1 }
    )
    snap = store.snapshot(pair)
    expect(snap[:active_walls][:bid]).to be_empty
  end

  it 'caps recent_sweeps ring at 8' do
    9.times do |i|
    bus.publish(
      :'liquidity.sweep.detected',
      { pair: pair, source: :binance, side: :bid, levels_swept: 3, notional: BigDecimal('1'), ts: t0 + i }
      )
    end
    expect(store.snapshot(pair)[:recent_sweeps].size).to eq(8)
    expect(store.snapshot(pair)[:recent_sweeps].last[:ts]).to eq(t0 + 8)
  end

  it 'caps recent_icebergs at 5 and voids per side at 4' do
    6.times do |i|
      bus.publish(
        :'liquidity.iceberg.suspected',
        { pair: pair, source: :binance, side: :ask, price: BigDecimal('100'), score: BigDecimal('1'), ts: t0 + i }
      )
    end
    expect(store.snapshot(pair)[:recent_icebergs].size).to eq(5)

    5.times do |i|
      bus.publish(
        :'liquidity.void.detected',
        { pair: pair, source: :binance, side: :ask, void_start: BigDecimal('100'), void_end: BigDecimal('101'),
          ts: t0 + i }
      )
    end
    expect(store.snapshot(pair)[:voids][:ask].size).to eq(4)
  end

  it 'records confirmed zones per side' do
    bus.publish(
      :'liquidity.zone.confirmed',
      { pair: pair, source: :binance, side: :bid, price_band: BigDecimal('98'), ts: t0 }
    )
    z = store.snapshot(pair)[:confirmed_zones][:bid]
    expect(z.size).to eq(1)
    expect(z.first[:price_band]).to eq(BigDecimal('98'))
  end

  it 'merges divergence snapshot from lookup' do
    s = store.snapshot(pair)
    expect(s[:divergence][:status]).to eq(:ok)
    expect(s[:divergence][:bps]).to eq(BigDecimal('1.2'))
  end

  it 'clear_pair removes cached state' do
    bus.publish(:orderflow_imbalance, { pair: pair, value: 0.1, bias: :bullish, depth: 5, source: :binance, ts: t0 })
    store.clear_pair(pair)
    expect(store.snapshot(pair)[:last_touch_ms]).to be_nil
  end
end
