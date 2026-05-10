# frozen_string_literal: true

# Verifies transition-based emission for binance-source orderflow events while keeping
# the legacy coindcx pathway untouched (engine_spec covers backward compat directly).
RSpec.describe 'CoindcxBot::Orderflow::Engine dedup integration' do
  let(:bus) { CoindcxBot::Core::EventBus.new }
  let(:config) do
    instance_double(
      'Config',
      orderflow_section: {
        imbalance_depth: 5,
        imbalance_spike_threshold: 0.25,
        wall_multiplier: 1.5,
        spoof_threshold: 1_000_000.0,
        absorption_volume_threshold: 1_000_000.0,
        record_sessions: false,
        walls: { dedup: { size_change_pct: 0.25, removal_grace_ms: 100, price_band_ticks: 1, tick_size: '0.01' } },
        imbalance: { dedup: { min_emit_interval_ms: 0, magnitude_change_pct: 0.5 } },
      }
    )
  end
  let(:engine) { CoindcxBot::Orderflow::Engine.new(bus: bus, config: config, logger: nil) }

  describe 'imbalance bucket dedup' do
    it 'emits exactly once across many snapshots within the same bias bucket' do
      emissions = []
      bus.subscribe(:orderflow_imbalance) { |p| emissions << p[:bias] }

      100.times do
        engine.on_book_update(
          pair: 'B-SOL_USDT',
          bids: [{ price: '100', quantity: '70' }],
          asks: [{ price: '101', quantity: '30' }],
          source: :binance
        )
      end

      expect(emissions.size).to eq(1)
      expect(emissions.first).to eq(:bullish)
    end

    it 'emits again when the bucket flips' do
      emissions = []
      bus.subscribe(:orderflow_imbalance) { |p| emissions << p[:bias] }

      engine.on_book_update(
        pair: 'B-SOL_USDT',
        bids: [{ price: '100', quantity: '70' }],
        asks: [{ price: '101', quantity: '30' }],
        source: :binance
      )
      engine.on_book_update(
        pair: 'B-SOL_USDT',
        bids: [{ price: '100', quantity: '30' }],
        asks: [{ price: '101', quantity: '70' }],
        source: :binance
      )

      expect(emissions).to eq(%i[bullish bearish])
    end
  end

  describe 'wall dedup' do
    let(:wall_book) do
      {
        bids: [
          { price: '99.99', quantity: '10' },
          { price: '99.98', quantity: '10' },
          { price: '99.50', quantity: '5000' },
        ],
        asks: [
          { price: '100.01', quantity: '10' },
          { price: '100.02', quantity: '10' },
          { price: '100.50', quantity: '5000' },
        ],
      }
    end

    it 'emits orderflow_walls and wall.detected only once for an unchanged book' do
      walls_emissions = []
      detected_emissions = []
      bus.subscribe(:orderflow_walls) { |p| walls_emissions << p }
      bus.subscribe(:'liquidity.wall.detected') { |p| detected_emissions << [p[:side], p[:price]] }

      5.times do
        engine.on_book_update(pair: 'B-SOL_USDT', bids: wall_book[:bids], asks: wall_book[:asks], source: :binance)
      end

      expect(walls_emissions.size).to eq(1)
      expect(detected_emissions.size).to eq(2)
    end

    it 'emits wall.removed after the configured grace period' do
      removed = []
      bus.subscribe(:'liquidity.wall.removed') { |p| removed << [p[:side], p[:price]] }

      base_ts = (Time.now.to_f * 1000).to_i

      engine.on_book_update(pair: 'B-SOL_USDT', bids: wall_book[:bids], asks: wall_book[:asks], source: :binance, ts: base_ts)
      engine.on_book_update(pair: 'B-SOL_USDT',
                            bids: [{ price: '99.99', quantity: '10' }],
                            asks: [{ price: '100.01', quantity: '10' }],
                            source: :binance, ts: base_ts + 50)
      expect(removed).to be_empty

      engine.on_book_update(pair: 'B-SOL_USDT',
                            bids: [{ price: '99.99', quantity: '10' }],
                            asks: [{ price: '100.01', quantity: '10' }],
                            source: :binance, ts: base_ts + 200)

      expect(removed.map(&:first).sort).to eq(%i[ask bid])
    end

    it 'leaves the coindcx path emitting per-snapshot (backward compatibility)' do
      walls_emissions = 0
      bus.subscribe(:orderflow_walls) { |_p| walls_emissions += 1 }

      3.times do
        engine.on_book_update(pair: 'B-SOL_USDT', bids: wall_book[:bids], asks: wall_book[:asks], source: :coindcx)
      end

      expect(walls_emissions).to eq(3)
    end
  end
end
