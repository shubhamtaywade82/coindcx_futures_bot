# frozen_string_literal: true

require 'bigdecimal'

RSpec.describe CoindcxBot::Orderflow::LiquidityVoidDetector do
  let(:bus) { CoindcxBot::Core::EventBus.new }
  let(:captured) { [] }

  let(:config) do
    double(
      orderflow_section: {
        void: { enabled: true, depth: 10, multiplier: BigDecimal('1.1') }
      }
    )
  end

  before { bus.subscribe(:'liquidity.void.detected') { |e| captured << e } }

  it 'emits when one gap dwarfs the average gap' do
    det = described_class.new(bus: bus, config: config)
    asks = {
      '100' => 1.0,
      '101' => 1.0,
      '200' => 1.0
    }
    det.on_book(pair: 'P', bids: { '99' => 1.0 }, asks: asks, source: :binance, ts_ms: 1)
    expect(captured).not_to be_empty
    expect(captured.first[:side]).to eq(:ask)
  end

  it 'stays quiet on evenly spaced ladders' do
    det = described_class.new(bus: bus, config: config)
    asks = (1..10).map { |i| [(100 + i).to_s, 1.0] }.to_h
    det.on_book(pair: 'P', bids: {}, asks: asks, source: :binance, ts_ms: 1)
    expect(captured).to be_empty
  end
end
