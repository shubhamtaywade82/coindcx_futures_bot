# frozen_string_literal: true

require 'bigdecimal'

RSpec.describe CoindcxBot::Orderflow::IcebergDetector do
  let(:bus) { CoindcxBot::Core::EventBus.new }
  let(:captured) { [] }

  let(:config) do
    double(
      orderflow_section: {
        iceberg: {
          enabled: true,
          window_ms: 60_000,
          min_refills: 3,
          qty_tolerance: BigDecimal('0.2')
        }
      }
    )
  end

  before { bus.subscribe(:'liquidity.iceberg.suspected') { |e| captured << e } }

  it 'emits when refills track executed size within tolerance' do
    det = described_class.new(bus: bus, config: config)
    det.on_trade(pair: 'P', price: BigDecimal('100'), size: BigDecimal('10'), side: :buy, ts: 1_000_000, source: :binance)

    3.times do |i|
      det.feed_book_delta(
        pair: 'P',
        source: :binance,
        delta: {
          side: :ask,
          price: BigDecimal('100'),
          prev_qty: BigDecimal('1'),
          new_qty: BigDecimal('4'),
          action: :increase,
          ts_ms: 1_000_000 + i
        }
      )
    end

    expect(captured.size).to eq(1)
    expect(captured.first[:price]).to eq(BigDecimal('100'))
    expect(captured.first[:source]).to eq(:binance)
  end

  it 'does not emit when refills are far from fill quantity' do
    det = described_class.new(bus: bus, config: config)
    det.on_trade(pair: 'P', price: BigDecimal('100'), size: BigDecimal('10'), side: :buy, ts: 1, source: :binance)
    3.times do |i|
      det.feed_book_delta(
        pair: 'P',
        source: :binance,
        delta: {
          side: :ask,
          price: BigDecimal('100'),
          prev_qty: BigDecimal('1'),
          new_qty: BigDecimal('50'),
          action: :increase,
          ts_ms: 100 + i
        }
      )
    end
    expect(captured).to be_empty
  end
end
