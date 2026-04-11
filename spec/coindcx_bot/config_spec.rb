# frozen_string_literal: true

require 'bigdecimal'

RSpec.describe CoindcxBot::Config do
  it 'reads risk.flatten_on_daily_loss_breach and pause_after_daily_loss_flatten' do
    on = described_class.new(minimal_bot_config(risk: minimal_bot_config[:risk].merge(flatten_on_daily_loss_breach: true, pause_after_daily_loss_flatten: true)))
    expect(on.flatten_on_daily_loss_breach?).to be(true)
    expect(on.pause_after_daily_loss_flatten?).to be(true)
  end

  it 'reads regime.ai.enabled as regime_ai_enabled? only when regime is on' do
    off = described_class.new(minimal_bot_config(regime: { enabled: false, ai: { enabled: true } }))
    expect(off.regime_ai_enabled?).to be(false)
    on = described_class.new(minimal_bot_config(regime: { enabled: true, ai: { enabled: true } }))
    expect(on.regime_ai_enabled?).to be(true)
  end

  it 'reads regime.enabled as regime_enabled?' do
    on = described_class.new(minimal_bot_config(regime: { enabled: true }))
    expect(on.regime_enabled?).to be(true)
    off = described_class.new(minimal_bot_config(regime: { enabled: false }))
    expect(off.regime_enabled?).to be(false)
  end

  it 'treats runtime.paper as dry_run (paper trading mode)' do
    cfg = described_class.new(
      minimal_bot_config(runtime: { journal_path: '/tmp/x.sqlite3', paper: true, dry_run: false })
    )
    expect(cfg.dry_run?).to be(true)
  end

  it 'rejects per_trade_inr_min greater than max' do
    bad = minimal_bot_config(risk: { per_trade_inr_min: 600, per_trade_inr_max: 500 })
    expect { described_class.new(bad) }.to raise_error(CoindcxBot::Config::ConfigurationError, /per-trade INR min/)
  end

  it 'derives per-trade clamps and daily loss from capital_inr when absolute INR limits are omitted' do
    cfg = described_class.new(
      minimal_bot_config(
        capital_inr: 200_000,
        risk: {
          per_trade_inr_min: nil,
          per_trade_inr_max: nil,
          max_daily_loss_inr: nil,
          max_open_positions: 2,
          max_leverage: 10
        }
      )
    )
    expect(cfg.resolved_per_trade_inr_min).to eq(BigDecimal('500'))
    expect(cfg.resolved_per_trade_inr_max).to eq(BigDecimal('6000'))
    expect(cfg.resolved_max_daily_loss_inr).to eq(BigDecimal('7000'))
  end

  it 'rejects per_trade_capital_pct without capital_inr' do
    bad = minimal_bot_config.merge(capital_inr: nil, risk: minimal_bot_config[:risk].merge(per_trade_capital_pct: 5))
    expect { described_class.new(bad) }.to raise_error(CoindcxBot::Config::ConfigurationError, /capital_inr/)
  end

  it 'rejects per_trade_capital_pct outside (0, 100]' do
    expect do
      described_class.new(minimal_bot_config(risk: { per_trade_capital_pct: 0 }))
    end.to raise_error(CoindcxBot::Config::ConfigurationError, /per_trade_capital_pct/)

    expect do
      described_class.new(minimal_bot_config(risk: { per_trade_capital_pct: 101 }))
    end.to raise_error(CoindcxBot::Config::ConfigurationError, /per_trade_capital_pct/)
  end

  it 'enables paper exchange when dry_run and paper_exchange.enabled are set' do
    cfg = described_class.new(
      minimal_bot_config(
        runtime: { dry_run: true },
        paper_exchange: { enabled: true, api_base_url: 'http://127.0.0.1:9292' }
      )
    )
    expect(cfg.paper_exchange_enabled?).to be(true)
    expect(cfg.paper_exchange_api_base).to eq('http://127.0.0.1:9292')
    expect(cfg.paper_exchange_tick_path).to eq('/exchange/v1/paper/simulation/tick')
  end

  it 'does not enable paper exchange when not in dry_run' do
    cfg = described_class.new(
      minimal_bot_config(
        runtime: { dry_run: false, paper: false },
        paper_exchange: { enabled: true, api_base_url: 'http://127.0.0.1:9292' }
      )
    )
    expect(cfg.paper_exchange_enabled?).to be(false)
  end

  it 'accepts up to Config::MAX_PAIRS instruments' do
    many = (1..CoindcxBot::Config::MAX_PAIRS).map { |i| "B-COIN#{i}_USDT" }
    cfg = described_class.new(minimal_bot_config(pairs: many))
    expect(cfg.pairs.size).to eq(CoindcxBot::Config::MAX_PAIRS)
  end

  it 'rejects an empty pairs list' do
    expect do
      described_class.new(minimal_bot_config(pairs: []))
    end.to raise_error(CoindcxBot::Config::ConfigurationError, /must list 1–/)
  end

  it 'rejects more than Config::MAX_PAIRS instruments' do
    too_many = (1..(CoindcxBot::Config::MAX_PAIRS + 1)).map { |i| "B-COIN#{i}_USDT" }
    expect do
      described_class.new(minimal_bot_config(pairs: too_many))
    end.to raise_error(CoindcxBot::Config::ConfigurationError, /got #{CoindcxBot::Config::MAX_PAIRS + 1}/)
  end

  describe 'scalper mode' do
    around do |ex|
      prev = ENV[CoindcxBot::ScalperProfile::ENV_KEY]
      ENV.delete(CoindcxBot::ScalperProfile::ENV_KEY)
      ex.run
      if prev
        ENV[CoindcxBot::ScalperProfile::ENV_KEY] = prev
      else
        ENV.delete(CoindcxBot::ScalperProfile::ENV_KEY)
      end
    end

    it 'applies scalper defaults for missing keys when runtime.mode is scalper' do
      base = minimal_bot_config
      cfg = described_class.new(
        base.merge(
          runtime: base[:runtime].except(:refresh_candles_seconds).merge(mode: 'scalper'),
          strategy: base[:strategy].except(:execution_resolution, :higher_timeframe_resolution)
        )
      )
      expect(cfg.scalper_mode?).to be(true)
      expect(cfg.trading_mode_label).to eq('SCALP')
      expect(cfg.runtime[:refresh_candles_seconds]).to eq(12)
      expect(cfg.strategy[:execution_resolution]).to eq('5m')
      expect(cfg.strategy[:higher_timeframe_resolution]).to eq('15m')
      expect(cfg.flatten_on_daily_loss_breach?).to be(true)
      expect(cfg.pause_after_daily_loss_flatten?).to be(true)
    end

    it 'does not override explicit runtime or strategy keys when scalper' do
      cfg = described_class.new(
        minimal_bot_config(
          runtime: minimal_bot_config[:runtime].merge(mode: 'scalper', refresh_candles_seconds: 30),
          strategy: minimal_bot_config[:strategy].merge(execution_resolution: '1h')
        )
      )
      expect(cfg.runtime[:refresh_candles_seconds]).to eq(30)
      expect(cfg.strategy[:execution_resolution]).to eq('1h')
      expect(cfg.strategy[:higher_timeframe_resolution]).to eq('1h')
    end

    it 'enables scalper via ENV and forces swing off via COINDCX_BOT_MODE=swing' do
      ENV[CoindcxBot::ScalperProfile::ENV_KEY] = 'scalper'
      expect(described_class.new(minimal_bot_config).scalper_mode?).to be(true)

      ENV[CoindcxBot::ScalperProfile::ENV_KEY] = 'swing'
      cfg = described_class.new(
        minimal_bot_config(
          runtime: minimal_bot_config[:runtime].merge(mode: 'scalper')
        )
      )
      expect(cfg.scalper_mode?).to be(false)
      expect(cfg.runtime[:refresh_candles_seconds]).to eq(60)
    end
  end
end
