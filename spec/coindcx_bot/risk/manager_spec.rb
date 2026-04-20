# frozen_string_literal: true

RSpec.describe CoindcxBot::Risk::Manager do
  let(:journal_path) { Tempfile.new(['rj', '.sqlite3']).path }
  let(:journal) { CoindcxBot::Persistence::Journal.new(journal_path) }
  let(:config) { CoindcxBot::Config.new(minimal_bot_config) }
  let(:guard) { CoindcxBot::Risk::ExposureGuard.new(config: config) }
  let(:fx) { instance_double(CoindcxBot::Fx::UsdtInrRate, inr_per_usdt: config.inr_per_usdt) }

  subject(:manager) { described_class.new(config: config, journal: journal, exposure_guard: guard, fx: fx) }

  after do
    journal.close
    File.delete(journal_path) if File.exist?(journal_path)
  end

  it 'rejects new entries when kill switch is on' do
    journal.set_kill_switch(true)
    code, = manager.allow_new_entry?(open_positions: [], pair: 'B-SOL_USDT')
    expect(code).to eq(:reject)
  end

  it 'rejects when two positions are already open' do
    journal.insert_position(
      pair: 'B-SOL_USDT', side: 'long', entry_price: BigDecimal('1'), quantity: BigDecimal('1'),
      stop_price: BigDecimal('0.9'), trail_price: nil
    )
    journal.insert_position(
      pair: 'B-ETH_USDT', side: 'long', entry_price: BigDecimal('1'), quantity: BigDecimal('1'),
      stop_price: BigDecimal('0.9'), trail_price: nil
    )
    open = journal.open_positions
    code, reason = manager.allow_new_entry?(open_positions: open, pair: 'B-DOGE_USDT')
    expect(code).to eq(:reject)
    expect(reason).to eq('max_positions')
  end

  it 'flags daily loss breach' do
    journal.add_daily_pnl_inr(BigDecimal('-2000'))
    expect(manager.daily_loss_breached?).to be true
  end

  it 'sizes quantity from INR risk and stop distance' do
    qty = manager.size_quantity(entry_price: BigDecimal('100'), stop_price: BigDecimal('98'), side: :long)
    expect(qty).to be > 0
  end

  it 'uses midpoint of per_trade_inr min and max for risk budget' do
    cfg = CoindcxBot::Config.new(
      minimal_bot_config(risk: { per_trade_inr_min: 200, per_trade_inr_max: 400, max_daily_loss_inr: 1500 })
    )
    mid_fx = instance_double(CoindcxBot::Fx::UsdtInrRate, inr_per_usdt: cfg.inr_per_usdt)
    mid_manager = described_class.new(config: cfg, journal: journal, exposure_guard: guard, fx: mid_fx)
    qty = mid_manager.size_quantity(entry_price: BigDecimal('100'), stop_price: BigDecimal('98'), side: :long)
    expected_risk_usdt = BigDecimal('300') / BigDecimal('83')
    expected_qty = (expected_risk_usdt / BigDecimal('2')).round(6, BigDecimal::ROUND_DOWN)
    expect(qty).to eq(expected_qty)
  end

  it 'uses per_trade_capital_pct of capital_inr as risk budget, clamped to min and max INR' do
    cfg = CoindcxBot::Config.new(
      minimal_bot_config(
        capital_inr: 100_000,
        risk: {
          per_trade_capital_pct: 10,
          per_trade_inr_min: 250,
          per_trade_inr_max: 500,
          max_daily_loss_inr: 1500
        }
      )
    )
    pct_fx = instance_double(CoindcxBot::Fx::UsdtInrRate, inr_per_usdt: cfg.inr_per_usdt)
    pct_manager = described_class.new(
      config: cfg,
      journal: journal,
      exposure_guard: CoindcxBot::Risk::ExposureGuard.new(config: cfg),
      fx: pct_fx
    )
    qty = pct_manager.size_quantity(entry_price: BigDecimal('100'), stop_price: BigDecimal('98'), side: :long)
    expected_risk_inr = BigDecimal('500')
    expected_risk_usdt = expected_risk_inr / BigDecimal('83')
    expected_qty = (expected_risk_usdt / BigDecimal('2')).round(6, BigDecimal::ROUND_DOWN)
    expect(qty).to eq(expected_qty)
  end

  it 'uses 1.5% of capital_inr as per-trade budget when absolute clamps and per_trade_capital_pct are omitted' do
    cfg = CoindcxBot::Config.new(
      minimal_bot_config(
        capital_inr: 100_000,
        risk: {
          per_trade_inr_min: nil,
          per_trade_inr_max: nil,
          max_daily_loss_inr: nil,
          max_open_positions: 2,
          max_leverage: 10
        }
      )
    )
    dyn_fx = instance_double(CoindcxBot::Fx::UsdtInrRate, inr_per_usdt: cfg.inr_per_usdt)
    dyn = described_class.new(
      config: cfg,
      journal: journal,
      exposure_guard: CoindcxBot::Risk::ExposureGuard.new(config: cfg),
      fx: dyn_fx
    )
    qty = dyn.size_quantity(entry_price: BigDecimal('100'), stop_price: BigDecimal('98'), side: :long)
    expected_risk_inr = BigDecimal('1500')
    expected_risk_usdt = expected_risk_inr / BigDecimal('83')
    expected_qty = (expected_risk_usdt / BigDecimal('2')).round(6, BigDecimal::ROUND_DOWN)
    expect(qty).to eq(expected_qty)
  end

  describe 'circuit breaker' do
    let(:cb_config) do
      CoindcxBot::Config.new(
        minimal_bot_config(
          risk: {
            per_trade_inr_min: 250, per_trade_inr_max: 500, max_daily_loss_inr: 5000,
            consecutive_loss_limit: 3, circuit_breaker_cooldown_minutes: 60
          }
        )
      )
    end
    let(:cb_fx) { instance_double(CoindcxBot::Fx::UsdtInrRate, inr_per_usdt: cb_config.inr_per_usdt) }
    let(:cb_guard) { CoindcxBot::Risk::ExposureGuard.new(config: cb_config) }
    subject(:cb_manager) { described_class.new(config: cb_config, journal: journal, exposure_guard: cb_guard, fx: cb_fx) }

    def log_paper_realized(pnl_usdt)
      journal.log_event('paper_realized', { pnl_usdt: pnl_usdt.to_s })
    end

    it 'triggers after 3 consecutive losses with no interleaved events' do
      3.times { log_paper_realized(-10) }
      result, reason = cb_manager.allow_new_entry?(open_positions: [], pair: 'B-SOL_USDT')
      expect(result).to eq(:reject)
      expect(reason).to eq('circuit_breaker_streak')
    end

    it 'triggers after 3 consecutive losses even when trail/smc events are interleaved' do
      log_paper_realized(-10)
      journal.log_event('trail_update', { pair: 'B-SOL_USDT', new_stop: '98' })
      journal.log_event('smc_setup_invalidated', { pair: 'B-SOL_USDT' })
      log_paper_realized(-8)
      journal.log_event('trail_update', { pair: 'B-ETH_USDT', new_stop: '1800' })
      log_paper_realized(-5)
      result, reason = cb_manager.allow_new_entry?(open_positions: [], pair: 'B-SOL_USDT')
      expect(result).to eq(:reject)
      expect(reason).to eq('circuit_breaker_streak')
    end

    it 'does not trigger when the last N trades include a winning trade' do
      log_paper_realized(-10)
      log_paper_realized(5)  # win breaks the streak
      log_paper_realized(-8)
      result, = cb_manager.allow_new_entry?(open_positions: [], pair: 'B-SOL_USDT')
      expect(result).to eq(:ok)
    end
  end

  it 'raises per-trade INR budget from pct when raw pct budget is below min' do
    cfg = CoindcxBot::Config.new(
      minimal_bot_config(
        capital_inr: 10_000,
        risk: {
          per_trade_capital_pct: 1,
          per_trade_inr_min: 250,
          per_trade_inr_max: 500,
          max_daily_loss_inr: 1500
        }
      )
    )
    pct_fx2 = instance_double(CoindcxBot::Fx::UsdtInrRate, inr_per_usdt: cfg.inr_per_usdt)
    pct_manager = described_class.new(
      config: cfg,
      journal: journal,
      exposure_guard: CoindcxBot::Risk::ExposureGuard.new(config: cfg),
      fx: pct_fx2
    )
    qty = pct_manager.size_quantity(entry_price: BigDecimal('100'), stop_price: BigDecimal('98'), side: :long)
    expected_risk_inr = BigDecimal('250')
    expected_risk_usdt = expected_risk_inr / BigDecimal('83')
    expected_qty = (expected_risk_usdt / BigDecimal('2')).round(6, BigDecimal::ROUND_DOWN)
    expect(qty).to eq(expected_qty)
  end
end
