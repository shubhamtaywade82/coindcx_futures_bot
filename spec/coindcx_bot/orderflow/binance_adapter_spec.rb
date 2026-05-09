# frozen_string_literal: true

require 'bigdecimal'

RSpec.describe CoindcxBot::Orderflow::BinanceAdapter do
  let(:bus) { CoindcxBot::Core::EventBus.new }

  let(:config) do
    double(
      orderflow_section: {
        record_sessions: false,
        imbalance_depth: 5,
        wall_multiplier: 10_000.0,
        spoof_threshold: 10_000.0,
        absorption_volume_threshold: 1_000_000.0
      }
    )
  end

  let(:book) { CoindcxBot::Exchanges::Binance::LocalBook.new }

  let(:trade_ws) do
    tw = instance_double(CoindcxBot::Exchanges::Binance::TradeWs)
    allow(tw).to receive(:on_trade)
    allow(tw).to receive(:connect)
    allow(tw).to receive(:disconnect)
    tw
  end

  let(:manager) do
    bk = book
    cb_slot = []
    m = Object.new
    m.define_singleton_method(:after_apply=) { |cb| cb_slot[0] = cb }
    m.define_singleton_method(:start) do
      bk.replace!(last_update_id: 1, bids: [['100', '1']], asks: [['101', '1']])
      ev = CoindcxBot::Exchanges::Binance::DepthWs::Event.new(
        event_type: 'depthUpdate',
        symbol: 'SOLUSDT',
        first_u: 1,
        final_u: 2,
        prev_u: nil,
        event_time: 1_700_000_000_000,
        tx_time: 0,
        bids: [],
        asks: []
      )
      2.times { cb_slot[0].call('SOLUSDT', bk, ev) }
    end
    m.define_singleton_method(:stop) {}
    m
  end

  it 'forwards throttled book updates to the engine with source :binance' do
    engine_calls = []
    engine = CoindcxBot::Orderflow::Engine.new(bus: bus, config: config, logger: nil)
    allow(engine).to receive(:on_book_update) { |**kw| engine_calls << kw }

    described_class.new(
      engine: engine,
      book: book,
      manager: manager,
      trade_ws: trade_ws,
      coindcx_pair: 'B-SOL_USDT',
      sweep_detector: nil,
      iceberg_detector: nil
    ).start

    expect(engine_calls.size).to eq(1)
    expect(engine_calls.first[:source]).to eq(:binance)
    expect(engine_calls.first[:pair]).to eq('B-SOL_USDT')
  end
end
