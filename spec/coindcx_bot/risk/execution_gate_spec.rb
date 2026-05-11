# frozen_string_literal: true

require 'bigdecimal'

RSpec.describe CoindcxBot::Risk::ExecutionGate do
  let(:bus) { CoindcxBot::Core::EventBus.new }
  let(:logger) { nil }
  let(:pair) { 'B-SOL_USDT' }
  let(:now) { 5_000_000 }

  def make_config(gate: {})
    default_gate = { enabled: true, block_unmapped_pairs: false, cooldown_ms: 1_000 }
    CoindcxBot::Config.new(
      minimal_bot_config(
        orderflow: {
          divergence: {
            max_bps: 25,
            max_lag_ms: 1_500,
            check_interval_ms: 250,
            gate: default_gate.merge(gate)
          }
        }
      )
    )
  end

  let(:guard) { CoindcxBot::Risk::DivergenceGuard.new(max_bps: BigDecimal('25'), max_lag_ms: 1_500) }

  def seed_guard_ok(g, wall: now)
    g.update_binance_mid(symbol: 'SOLUSDT', mid: BigDecimal('100'), ts: wall - 50)
    g.update_coindcx_mid(pair: pair, mid: BigDecimal('100.01'), ts: wall - 55)
  end

  it 'returns ok when gate disabled regardless of guard' do
    cfg = make_config(gate: { enabled: false })
    gate = described_class.new(divergence_guards: { pair => guard }, config: cfg, logger: logger, bus: bus)
    expect(gate.gate?(action: :open_long, pair: pair)).to be_ok
  end

  it 'returns ok for exit-style actions' do
    cfg = make_config
    gate = described_class.new(divergence_guards: { pair => guard }, config: cfg, logger: logger, bus: bus)
    expect(gate.gate?(action: :close, pair: pair)).to be_ok
    expect(gate.gate?(action: :partial, pair: pair)).to be_ok
    expect(gate.gate?(action: :trail, pair: pair)).to be_ok
    expect(gate.gate?(action: :hold, pair: pair)).to be_ok
  end

  it 'returns ok for unmapped CoinDCX pair when block_unmapped_pairs is false' do
    cfg = make_config
    gate = described_class.new(divergence_guards: {}, config: cfg, logger: logger, bus: bus)
    expect(gate.gate?(action: :open_short, pair: 'B-XYZ_USDT')).to be_ok
  end

  it 'returns err for unmapped pair when block_unmapped_pairs is true' do
    cfg = make_config(gate: { block_unmapped_pairs: true })
    gate = described_class.new(divergence_guards: {}, config: cfg, logger: logger, bus: bus)
    r = gate.gate?(action: :open_long, pair: 'B-XYZ_USDT')
    expect(r).to be_failure
    expect(r.code).to eq(:pair_not_binance_mapped)
  end

  it 'returns ok when pair is mapped but no guard is registered' do
    cfg = make_config
    gate = described_class.new(divergence_guards: {}, config: cfg, logger: logger, bus: bus)
    expect(gate.gate?(action: :open_long, pair: pair)).to be_ok
  end

  it 'returns ok when mapped pair and guard check passes' do
    seed_guard_ok(guard)
    cfg = make_config
    gate = described_class.new(divergence_guards: { pair => guard }, config: cfg, logger: logger, bus: bus)
    r = gate.gate?(action: :open_long, pair: pair, now_ms: now)
    expect(r).to be_ok
  end

  it 'propagates max_bps_exceeded from guard' do
    guard.update_binance_mid(symbol: 'SOLUSDT', mid: BigDecimal('110'), ts: now - 100)
    guard.update_coindcx_mid(pair: pair, mid: BigDecimal('100'), ts: now - 100)
    cfg = make_config
    gate = described_class.new(divergence_guards: { pair => guard }, config: cfg, logger: logger, bus: bus)
    r = gate.gate?(action: :open_short, pair: pair, now_ms: now)
    expect(r).to be_failure
    expect(r.code).to eq(:max_bps_exceeded)
    expect(r.value[:reason]).to eq(:max_bps_exceeded)
  end

  it 'propagates coindcx_stale from guard' do
    guard.update_binance_mid(symbol: 'SOLUSDT', mid: BigDecimal('100'), ts: now - 100)
    guard.update_coindcx_mid(pair: pair, mid: BigDecimal('100'), ts: now - 10_000)
    cfg = make_config
    gate = described_class.new(divergence_guards: { pair => guard }, config: cfg, logger: logger, bus: bus)
    r = gate.gate?(action: :open_long, pair: pair, now_ms: now)
    expect(r).to be_failure
    expect(r.code).to eq(:coindcx_stale)
  end

  it 'publishes risk.execution.blocked at most once per cooldown for repeated failures' do
    guard.update_binance_mid(symbol: 'SOLUSDT', mid: BigDecimal('110'), ts: now - 100)
    guard.update_coindcx_mid(pair: pair, mid: BigDecimal('100'), ts: now - 100)
    cfg = make_config
    blocked = []
    bus.subscribe(CoindcxBot::Risk::ExecutionGate::EVENT_BLOCKED) { |p| blocked << p }

    gate = described_class.new(divergence_guards: { pair => guard }, config: cfg, logger: logger, bus: bus)
    gate.gate?(action: :open_long, pair: pair, now_ms: now)
    gate.gate?(action: :open_long, pair: pair, now_ms: now)
    gate.gate?(action: :open_long, pair: pair, now_ms: now)

    expect(blocked.size).to eq(1)
    expect(blocked.first).to include(
      pair: pair,
      action: :open_long,
      reason: :max_bps_exceeded
    )
    expect(blocked.first).to have_key(:bps)
    expect(blocked.first).to have_key(:age_ms)
  end

  it 'accepts a GuardRegistry as divergence_guards' do
    seed_guard_ok(guard)
    reg = CoindcxBot::Risk::GuardRegistry.new.register(pair: pair, guard: guard)
    cfg = make_config
    gate = described_class.new(divergence_guards: reg, config: cfg, logger: logger, bus: bus)
    expect(gate.gate?(action: :open_long, pair: pair, now_ms: now)).to be_ok
  end

  it 'publishes risk.execution.unblocked after guard recovers from a blocking state' do
    cfg = make_config
    unblocked = []
    bus.subscribe(CoindcxBot::Risk::ExecutionGate::EVENT_UNBLOCKED) { |p| unblocked << p }

    gate = described_class.new(divergence_guards: { pair => guard }, config: cfg, logger: logger, bus: bus)
    guard.update_binance_mid(symbol: 'SOLUSDT', mid: BigDecimal('110'), ts: now - 100)
    guard.update_coindcx_mid(pair: pair, mid: BigDecimal('100'), ts: now - 100)
    gate.gate?(action: :open_long, pair: pair, now_ms: now)

    seed_guard_ok(guard, wall: now + 10_000)
    gate.gate?(action: :open_long, pair: pair, now_ms: now + 10_000)

    expect(unblocked.size).to eq(1)
    expect(unblocked.first).to eq({ pair: pair, action: :open_long })
  end
end
