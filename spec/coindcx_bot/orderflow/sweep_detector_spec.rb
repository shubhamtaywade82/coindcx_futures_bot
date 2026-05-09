# frozen_string_literal: true

require 'bigdecimal'

RSpec.describe CoindcxBot::Orderflow::SweepDetector do
  let(:bus) { CoindcxBot::Core::EventBus.new }
  let(:captured) { [] }

  let(:config) do
    double(
      orderflow_section: {
        sweep: {
          enabled: true,
          min_levels: 3,
          window_ms: 500,
          displacement_atr_mult: BigDecimal('0.3'),
          tick_size: '0.01'
        }
      }
    )
  end

  before do
    bus.subscribe(:'liquidity.sweep.detected') { |e| captured << e }
  end

  it 'emits when consecutive best bid removals exceed ATR-scaled displacement' do
    det = described_class.new(bus: bus, config: config)
    det.record_mid(pair: 'P', mid: BigDecimal('100'), ts_ms: 100)
    det.record_mid(pair: 'P', mid: BigDecimal('101'), ts_ms: 120)

    base = 1_000
    det.feed_local_delta(
      pair: 'P',
      source: :binance,
      delta: { side: :bid, action: :remove, was_best: true, price: BigDecimal('50.0'), prev_qty: BigDecimal('1'), ts_ms: base }
    )
    det.feed_local_delta(
      pair: 'P',
      source: :binance,
      delta: { side: :bid, action: :remove, was_best: true, price: BigDecimal('49.0'), prev_qty: BigDecimal('1'), ts_ms: base + 5 }
    )
    det.feed_local_delta(
      pair: 'P',
      source: :binance,
      delta: { side: :bid, action: :remove, was_best: true, price: BigDecimal('48.0'), prev_qty: BigDecimal('1'), ts_ms: base + 10 }
    )

    expect(captured.size).to eq(1)
    expect(captured.first[:levels_swept]).to eq(3)
    expect(captured.first[:source]).to eq(:binance)
  end

  it 'does not emit for isolated single removal' do
    det = described_class.new(bus: bus, config: config)
    det.record_mid(pair: 'P', mid: BigDecimal('50'), ts_ms: 100)
    det.feed_local_delta(
      pair: 'P',
      source: :binance,
      delta: { side: :bid, action: :remove, was_best: true, price: BigDecimal('50'), prev_qty: BigDecimal('1'), ts_ms: 200 }
    )
    expect(captured).to be_empty
  end

  it 'respects higher min_levels config' do
    strict = double(
      orderflow_section: {
        sweep: { enabled: true, min_levels: 5, window_ms: 500, displacement_atr_mult: 0.3, tick_size: '0.01' }
      }
    )
    det = described_class.new(bus: bus, config: strict)
    det.record_mid(pair: 'P', mid: BigDecimal('1'), ts_ms: 1)
    det.record_mid(pair: 'P', mid: BigDecimal('2'), ts_ms: 2)
    base = 10_000
    3.times do |i|
      det.feed_local_delta(
        pair: 'P',
        source: :binance,
        delta: { side: :bid, action: :remove, was_best: true, price: BigDecimal((100 - i).to_s), prev_qty: BigDecimal('1'), ts_ms: base + i }
      )
    end
    expect(captured).to be_empty
  end
end
