# frozen_string_literal: true

require 'bigdecimal'

RSpec.describe CoindcxBot::Config do
  it 'reads risk.flatten_on_daily_loss_breach and pause_after_daily_loss_flatten' do
    on = described_class.new(minimal_bot_config(risk: minimal_bot_config[:risk].merge(flatten_on_daily_loss_breach: true, pause_after_daily_loss_flatten: true)))
    expect(on.flatten_on_daily_loss_breach?).to be(true)
    expect(on.pause_after_daily_loss_flatten?).to be(true)
  end

  it 'reads smc_setup.enabled' do
    off = described_class.new(minimal_bot_config)
    expect(off.smc_setup_enabled?).to be(false)
    on = described_class.new(minimal_bot_config(smc_setup: { enabled: true }))
    expect(on.smc_setup_enabled?).to be(true)
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

  it 'defaults tui exchange position margins to [USDT, INR] when margin_currency_short_name is blank' do
    cfg = described_class.new(minimal_bot_config.merge(margin_currency_short_name: ''))
    expect(cfg.tui_exchange_positions_margin_currencies).to eq(%w[USDT INR])
  end

  it 'uses runtime.tui_exchange_positions_margins when set' do
    cfg = described_class.new(
      minimal_bot_config(runtime: { tui_exchange_positions_margins: %w[usdt inr] })
    )
    expect(cfg.tui_exchange_positions_margin_currencies).to eq(%w[USDT INR])
  end

  it 'rejects runtime.paper (use runtime.dry_run only)' do
    bad = minimal_bot_config(runtime: { paper: true })
    expect { described_class.new(bad) }.to raise_error(
      CoindcxBot::Config::ConfigurationError,
      /runtime\.paper/
    )
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
        runtime: { dry_run: false },
        paper_exchange: { enabled: true, api_base_url: 'http://127.0.0.1:9292' }
      )
    )
    expect(cfg.paper_exchange_enabled?).to be(false)
  end

  it 'defaults place_orders? to true when live and runtime.place_orders is omitted' do
    cfg = described_class.new(minimal_bot_config(runtime: { dry_run: false, journal_path: '/tmp/x.sqlite3' }))
    expect(cfg.place_orders?).to be(true)
  end

  it 'is false when live and runtime.place_orders is false' do
    cfg = described_class.new(
      minimal_bot_config(runtime: { dry_run: false, journal_path: '/tmp/x.sqlite3', place_orders: false })
    )
    expect(cfg.place_orders?).to be(false)
  end

  it 'treats place_orders? as true in paper mode regardless of runtime.place_orders' do
    cfg = described_class.new(
      minimal_bot_config(runtime: { dry_run: true, journal_path: '/tmp/x.sqlite3', place_orders: false })
    )
    expect(cfg.place_orders?).to be(true)
  end

  it 'enables tui_exchange_mirror when live and place_orders is false' do
    cfg = described_class.new(
      minimal_bot_config(
        runtime: {
          dry_run: false,
          journal_path: '/tmp/x.sqlite3',
          place_orders: false,
          tui_exchange_positions: true
        }
      )
    )
    expect(cfg.tui_exchange_mirror?).to be(true)
  end

  it 'disables tui_exchange_mirror when live with place_orders unless runtime.tui_exchange_mirror is set' do
    cfg = described_class.new(
      minimal_bot_config(
        runtime: {
          dry_run: false,
          journal_path: '/tmp/x.sqlite3',
          place_orders: true,
          tui_exchange_positions: true
        }
      )
    )
    expect(cfg.tui_exchange_mirror?).to be(false)
  end

  it 'lets PLACE_ORDER env override YAML when live' do
    prev = ENV['PLACE_ORDER']
    ENV['PLACE_ORDER'] = '0'
    cfg = described_class.new(
      minimal_bot_config(runtime: { dry_run: false, journal_path: '/tmp/x.sqlite3', place_orders: true })
    )
    expect(cfg.place_orders?).to be(false)
  ensure
    prev.nil? ? ENV.delete('PLACE_ORDER') : ENV['PLACE_ORDER'] = prev
  end

  it 'fx_enabled? defaults true when fx section absent' do
    cfg = described_class.new(minimal_bot_config)
    expect(cfg.fx_enabled?).to be(true)
  end

  it 'fx_enabled? is false when fx.enabled is false' do
    cfg = described_class.new(minimal_bot_config(fx: { enabled: false }))
    expect(cfg.fx_enabled?).to be(false)
  end

  it 'fx_ttl_seconds defaults to 60 and clamps low values to 5' do
    expect(described_class.new(minimal_bot_config).fx_ttl_seconds).to eq(60)
    expect(described_class.new(minimal_bot_config(fx: { ttl_seconds: 2 })).fx_ttl_seconds).to eq(5)
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

  describe 'meta_first_win strategy' do
    it 'accepts a valid meta_first_win block' do
      cfg = described_class.new(
        minimal_bot_config(
          strategy: {
            name: 'meta_first_win',
            execution_resolution: '15m',
            higher_timeframe_resolution: '1h',
            meta_first_win: {
              cooldown_seconds_after_close: 3,
              children: [
                { name: 'trend_continuation', trend_strength_min: 0.2 },
                { name: 'supertrend_profit' }
              ]
            }
          }
        )
      )
      expect(cfg.strategy_name).to eq('meta_first_win')
      expect(cfg.meta_first_win_strategy?).to be(true)
      expect(cfg.meta_first_win_cooldown_seconds_after_close).to eq(3.0)
    end

    it 'defaults strategy_name to trend_continuation when name is omitted' do
      cfg = described_class.new(minimal_bot_config)
      expect(cfg.strategy_name).to eq('trend_continuation')
      expect(cfg.meta_first_win_cooldown_seconds_after_close).to eq(0)
    end

    it 'rejects meta_first_win without children' do
      bad = minimal_bot_config(
        strategy: {
          name: 'meta_first_win',
          meta_first_win: { children: [] }
        }
      )
      expect { described_class.new(bad) }.to raise_error(CoindcxBot::Config::ConfigurationError, /children/)
    end

    it 'rejects an unsupported child name' do
      bad = minimal_bot_config(
        strategy: {
          name: 'meta_first_win',
          meta_first_win: { children: [{ name: 'regime_vol_tier' }] }
        }
      )
      expect { described_class.new(bad) }.to raise_error(CoindcxBot::Config::ConfigurationError, /unsupported/)
    end
  end

  describe 'telegram journal notifications' do
    around do |example|
      keys = %w[
        COINDCX_TELEGRAM_NOTIFY
        COINDCX_TELEGRAM_BOT_TOKEN
        COINDCX_TELEGRAM_CHAT_ID
        COINDCX_TELEGRAM_OPS_CHAT_ID
        COINDCX_TELEGRAM_OPS_BOT_TOKEN
      ]
      saved = keys.to_h { |k| [k, ENV[k]] }
      keys.each { |k| ENV.delete(k) }
      example.run
    ensure
      saved.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    end

    it 'is not ready when disabled and env unset' do
      cfg = described_class.new(minimal_bot_config)
      expect(cfg.telegram_journal_notifications_ready?).to be(false)
    end

    it 'is ready when telegram is enabled in yaml and credentials are in ENV' do
      ENV['COINDCX_TELEGRAM_BOT_TOKEN'] = 'secret'
      ENV['COINDCX_TELEGRAM_CHAT_ID'] = '99'
      cfg = described_class.new(minimal_bot_config(notifications: { telegram: { enabled: true } }))
      expect(cfg.telegram_journal_notifications_ready?).to be(true)
    end

    it 'is ready when COINDCX_TELEGRAM_NOTIFY is set with credentials' do
      ENV['COINDCX_TELEGRAM_NOTIFY'] = '1'
      ENV['COINDCX_TELEGRAM_BOT_TOKEN'] = 't'
      ENV['COINDCX_TELEGRAM_CHAT_ID'] = '1'
      cfg = described_class.new(minimal_bot_config)
      expect(cfg.telegram_journal_notifications_ready?).to be(true)
    end

    it 'defaults ops duplicate types' do
      cfg = described_class.new(minimal_bot_config)
      expect(cfg.telegram_journal_ops_duplicate_types).to eq(%w[open_failed smc_setup_invalidated])
    end

    it 'honors notify_ops_types yaml when present' do
      cfg = described_class.new(minimal_bot_config(notifications: { telegram: { notify_ops_types: %w[a] } }))
      expect(cfg.telegram_journal_ops_duplicate_types).to eq(%w[a])
    end

    it 'treats empty notify_ops_types as an explicit empty list' do
      cfg = described_class.new(minimal_bot_config(notifications: { telegram: { notify_ops_types: [] } }))
      expect(cfg.telegram_journal_ops_duplicate_types).to eq([])
    end
  end
end
