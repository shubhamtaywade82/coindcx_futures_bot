# frozen_string_literal: true

RSpec.describe CoindcxBot::SmcSetup::TickEvaluator do
  let(:path) { Tempfile.new(['smc_ev', '.sqlite3']).path }
  let(:journal) { CoindcxBot::Persistence::Journal.new(path) }
  let(:config) do
    CoindcxBot::Config.new(
      minimal_bot_config(
        pairs: %w[B-SOL_USDT],
        smc_setup: { enabled: true, auto_execute: true, sweep_consecutive_ticks: 1 }
      )
    )
  end
  let(:guard) { CoindcxBot::Risk::ExposureGuard.new(config: config) }
  let(:fx) { instance_double(CoindcxBot::Fx::UsdtInrRate, inr_per_usdt: config.inr_per_usdt) }
  let(:risk) { CoindcxBot::Risk::Manager.new(config: config, journal: journal, exposure_guard: guard, fx: fx) }
  let(:store) { CoindcxBot::SmcSetup::TradeSetupStore.new(journal: journal, max_active_setups_per_pair: 3) }
  let(:smc_cfg) { CoindcxBot::SmcConfluence::Configuration.new(vp_bars: 20, smc_swing: 3, ms_swing: 3, min_score: 10) }
  let(:coord) { instance_double(CoindcxBot::Execution::Coordinator, apply: :ok) }
  let(:setup_mutexes) { Hash.new { |h, k| h[k] = Mutex.new } }

  let(:evaluator) do
    described_class.new(
      config: config,
      journal: journal,
      coordinator: coord,
      risk: risk,
      store: store,
      logger: nil,
      smc_configuration: smc_cfg,
      regime_sizer: nil,
      setup_mutex_factory: ->(id) { setup_mutexes[id] }
    )
  end

  def dto_candles(n)
    Array.new(n) do |i|
      CoindcxBot::Dto::Candle.new(
        time: Time.utc(2024, 6, 1) + i * 900,
        open: 50 + i * 0.5,
        high: 51 + i * 0.5,
        low: 49 + i * 0.5,
        close: 50 + i * 0.5,
        volume: 1000
      )
    end
  end

  after do
    journal.close
    File.delete(path) if File.exist?(path)
  end

  it 'arms and calls coordinator once when ltp is in sweep and entry with no confirmations' do
    store.upsert_from_hash!(
      {
        schema_version: 1,
        setup_id: 'fire-1',
        pair: 'B-SOL_USDT',
        direction: 'long',
        conditions: {
          sweep_zone: { min: 40, max: 120 },
          entry_zone: { min: 90, max: 102 },
          confirmation_required: []
        },
        execution: { sl: 30.0, targets: [110.0] }
      }
    )
    store.reload!

    last_close = 50 + 99 * 0.5
    candles = dto_candles(100)

    expect(coord).to receive(:apply).once.and_return(:ok)

    evaluator.evaluate_pair!(
      pair: 'B-SOL_USDT',
      ltp: last_close,
      candles_exec: candles,
      stale: false
    )

    expect(journal.open_position_with_smc_setup?('fire-1')).to be(false)
    row = store.record_by_id('fire-1')
    expect(row.state).to eq(CoindcxBot::SmcSetup::States::ARMED_ENTRY)
  end

  it 'invalidates when LTP sits in conditions.no_trade_zone and lifecycle is enabled' do
    store.upsert_from_hash!(
      {
        schema_version: 1,
        setup_id: 'ntz-1',
        pair: 'B-SOL_USDT',
        direction: 'long',
        conditions: {
          sweep_zone: { min: 40, max: 120 },
          entry_zone: { min: 90, max: 102 },
          no_trade_zone: { min: 94.5, max: 95.5 },
          confirmation_required: []
        },
        execution: { sl: 30.0, targets: [110.0] }
      }
    )
    store.reload!

    cfg = CoindcxBot::Config.new(
      minimal_bot_config(
        pairs: %w[B-SOL_USDT],
        smc_setup: { enabled: true, auto_execute: true, sweep_consecutive_ticks: 1, lifecycle_enabled: true }
      )
    )
    ev = described_class.new(
      config: cfg,
      journal: journal,
      coordinator: coord,
      risk: CoindcxBot::Risk::Manager.new(config: cfg, journal: journal, exposure_guard: guard, fx: fx),
      store: store,
      logger: nil,
      smc_configuration: smc_cfg,
      regime_sizer: nil,
      setup_mutex_factory: ->(id) { setup_mutexes[id] }
    )

    ev.evaluate_pair!(
      pair: 'B-SOL_USDT',
      ltp: BigDecimal('95.0'),
      candles_exec: dto_candles(100),
      stale: false
    )

    row = journal.smc_setup_get_row('ntz-1')
    expect(row[:state]).to eq(CoindcxBot::SmcSetup::States::INVALIDATED)
  end

  it 'emits smc_setup_invalidated for time_expired at most once across ticks' do
    past = (Time.now.utc - 120).iso8601
    store.upsert_from_hash!(
      {
        schema_version: 1,
        setup_id: 'exp-once',
        pair: 'B-SOL_USDT',
        direction: 'long',
        expires_at: past,
        conditions: {
          sweep_zone: { min: 40, max: 120 },
          entry_zone: { min: 90, max: 102 },
          confirmation_required: []
        },
        execution: { sl: 30.0, targets: [110.0] }
      }
    )
    store.reload!

    # LTP near entry mid avoids lifecycle price_drift invalidation (still expired).
    5.times do
      evaluator.evaluate_pair!(
        pair: 'B-SOL_USDT',
        ltp: BigDecimal('96'),
        candles_exec: dto_candles(100),
        stale: false
      )
    end

    rows = journal.recent_events(30).select do |e|
      e['type'] == 'smc_setup_invalidated' && e['payload'].to_s.include?('exp-once')
    end
    expect(rows.size).to eq(1)
    payload = JSON.parse(rows.first['payload'], symbolize_names: true)
    expect(payload[:reason]).to eq('time_expired')
  end

  it 'does not call apply twice when journal already has the setup id open' do
    journal.insert_position(
      pair: 'B-SOL_USDT',
      side: 'long',
      entry_price: BigDecimal('99'),
      quantity: BigDecimal('0.01'),
      stop_price: BigDecimal('30'),
      trail_price: nil,
      smc_setup_id: 'already'
    )
    store.upsert_from_hash!(
      {
        schema_version: 1,
        setup_id: 'already',
        pair: 'B-SOL_USDT',
        direction: 'long',
        conditions: {
          sweep_zone: { min: 40, max: 120 },
          entry_zone: { min: 90, max: 102 },
          confirmation_required: []
        },
        execution: { sl: 30.0, targets: [110.0] }
      }
    )
    journal.smc_setup_update_state_and_eval(setup_id: 'already', state: CoindcxBot::SmcSetup::States::ARMED_ENTRY)
    store.reload!

    expect(coord).not_to receive(:apply)

    evaluator.evaluate_pair!(
      pair: 'B-SOL_USDT',
      ltp: BigDecimal('99'),
      candles_exec: dto_candles(100),
      stale: false
    )

    row = store.record_by_id('already')
    expect(row.state).to eq(CoindcxBot::SmcSetup::States::ACTIVE)
  end
end
