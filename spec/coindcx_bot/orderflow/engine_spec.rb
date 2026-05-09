# frozen_string_literal: true

RSpec.describe CoindcxBot::Orderflow::Engine do
  let(:bus) { CoindcxBot::Core::EventBus.new }
  let(:captured_liquidity_signals) { [] }
  let(:config) do
    instance_double(
      'Config',
      orderflow_section: {
        imbalance_depth: 5,
        wall_multiplier: 1000.0,
        spoof_threshold: 10_000.0,
        absorption_volume_threshold: 1_000_000.0,
        record_sessions: false
      }
    )
  end
  let(:engine) { described_class.new(bus: bus, config: config, logger: nil) }

  before do
    bus.subscribe(:orderflow_liquidity_shift) { |payload| captured_liquidity_signals << payload }
  end

  describe 'liquidity shift classification' do
    it 'marks ask removal as trade-through when buy trades consume the level' do
      seed_order_book
      engine.on_trade(pair: pair, price: 101.0, size: 70.0, side: :buy, ts: now_ms)

      engine.on_book_update(
        pair: pair,
        bids: [{ price: '100', quantity: '100' }],
        asks: []
      )

      event = last_liquidity_event
      expect(event[:type]).to eq(:ask_pull)
      expect(event[:classification]).to eq(:trade_through)
    end

    it 'marks ask removal as cancellation when no matching trade exists' do
      seed_order_book

      engine.on_book_update(
        pair: pair,
        bids: [{ price: '100', quantity: '100' }],
        asks: []
      )

      event = last_liquidity_event
      expect(event[:type]).to eq(:ask_pull)
      expect(event[:classification]).to eq(:cancel_or_requote)
    end

    it 'emits reduction events when a level size decreases without full removal' do
      seed_order_book

      engine.on_book_update(
        pair: pair,
        bids: [{ price: '100', quantity: '100' }],
        asks: [{ price: '101', quantity: '65' }]
      )

      event = last_liquidity_event
      expect(event[:type]).to eq(:ask_reduce)
      expect(event[:size]).to eq(35.0)
    end
  end

  private

  def pair
    'B-SOL_USDT'
  end

  def now_ms
    (Time.now.to_f * 1000.0).to_i
  end

  def seed_order_book
    engine.on_book_update(
      pair: pair,
      bids: [{ price: '100', quantity: '100' }],
      asks: [{ price: '101', quantity: '100' }]
    )
    captured_liquidity_signals.clear
  end

  def last_liquidity_event
    signal = captured_liquidity_signals.last
    expect(signal).not_to be_nil
    signal[:events].last
  end
end
