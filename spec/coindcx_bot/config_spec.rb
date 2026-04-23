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

  it 'reads regime.ai.include_feature_packet only when regime ai is enabled' do
    off = described_class.new(
      minimal_bot_config(regime: { enabled: true, ai: { enabled: false, include_feature_packet: true } })
    )
    expect(off.regime_ai_include_feature_packet?).to be(false)
    on = described_class.new(
      minimal_bot_config(regime: { enabled: true, ai: { enabled: true, include_feature_packet: true } })
    )
    expect(on.regime_ai_include_feature_packet?).to be(true)
  end

  it 'defaults regime ai feature_min_candles and omits raw bars only when packet is enabled' do
    cfg = described_class.new(
      minimal_bot_config(regime: { enabled: true, ai: { enabled: true, include_feature_packet: true } })
    )
    expect(cfg.regime_ai_feature_min_candles).to eq(30)
    expect(cfg.regime_ai_omit_raw_bars_when_feature_packet?).to be(false)
    cfg2 = described_class.new(
      minimal_bot_config(
        regime: {
          enabled: true,
          ai: {
            enabled: true,
            include_feature_packet: true,
            omit_raw_bars_when_feature_packet: true
          }
        }
      )
    )
    expect(cfg2.regime_ai_omit_raw_bars_when_feature_packet?).to be(true)
  end

  it 'reads smc_setup gatekeeper_include_feature_packet only when gatekeeper is enabled' do
    off = described_class.new(
      minimal_bot_config(
        smc_setup: { enabled: true, gatekeeper_enabled: false, gatekeeper_include_feature_packet: true }
      )
    )
    expect(off.smc_setup_gatekeeper_include_feature_packet?).to be(false)
    on = described_class.new(
      minimal_bot_config(
        smc_setup: { enabled: true, gatekeeper_enabled: true, gatekeeper_include_feature_packet: true }
      )
    )
    expect(on.smc_setup_gatekeeper_include_feature_packet?).to be(true)
  end

  it 'reads regime.enabled as regime_enabled?' do
    on = described_class.new(minimal_bot_config(regime: { enabled: true }))
    expect(on.regime_enabled?).to be(true)
    off = described_class.new(minimal_bot_config(regime: { enabled: false }))
    expect(off.regime_enabled?).to be(false)
  end

  it 'reads alerts.analysis.price_cross_cooldown_seconds' do
    cfg = described_class.new(
      minimal_bot_config(alerts: { analysis: { price_cross_cooldown_seconds: 120 } })
    )
    expect(cfg.alerts_analysis_price_cross_cooldown_seconds).to eq(120.0)
    expect(described_class.new(minimal_bot_config).alerts_analysis_price_cross_cooldown_seconds).to eq(0.0)
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

  it 'defaults alerts_filter_telegram? to false' do
    expect(described_class.new(minimal_bot_config).alerts_filter_telegram?).to be(false)
  end

  it 'reads alerts.filter_telegram from YAML' do
    cfg = described_class.new(minimal_bot_config(alerts: { filter_telegram: true }))
    expect(cfg.alerts_filter_telegram?).to be(true)
  end

  it 'defaults exit_on_hard_stop? to true' do
    expect(described_class.new(minimal_bot_config).exit_on_hard_stop?).to be(true)
  end

  it 'is false when strategy.exit_on_hard_stop is false' do
    cfg = described_class.new(
      minimal_bot_config(
        strategy: minimal_bot_config[:strategy].merge(exit_on_hard_stop: false)
      )
    )
    expect(cfg.exit_on_hard_stop?).to be(false)
  end

  it 'defaults paper_place_working_stop? to true' do
    expect(described_class.new(minimal_bot_config).paper_place_working_stop?).to be(true)
  end

  it 'is false when paper.place_working_stop is false' do
    cfg = described_class.new(
      minimal_bot_config(paper: minimal_bot_config[:paper].merge(place_working_stop: false))
    )
    expect(cfg.paper_place_working_stop?).to be(false)
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

  it 'lets PLACE_ORDERS env override YAML when live and PLACE_ORDER is unset' do
    prev_o = ENV['PLACE_ORDER']
    prev_os = ENV['PLACE_ORDERS']
    ENV.delete('PLACE_ORDER')
    ENV['PLACE_ORDERS'] = '0'
    cfg = described_class.new(
      minimal_bot_config(runtime: { dry_run: false, journal_path: '/tmp/x.sqlite3', place_orders: true })
    )
    expect(cfg.place_orders?).to be(false)
  ensure
    prev_o.nil? ? ENV.delete('PLACE_ORDER') : ENV['PLACE_ORDER'] = prev_o
    prev_os.nil? ? ENV.delete('PLACE_ORDERS') : ENV['PLACE_ORDERS'] = prev_os
  end

  it 'prefers PLACE_ORDER over PLACE_ORDERS when both are set' do
    prev_o = ENV['PLACE_ORDER']
    prev_os = ENV['PLACE_ORDERS']
    ENV['PLACE_ORDER'] = '0'
    ENV['PLACE_ORDERS'] = '1'
    cfg = described_class.new(
      minimal_bot_config(runtime: { dry_run: false, journal_path: '/tmp/x.sqlite3', place_orders: true })
    )
    expect(cfg.place_orders?).to be(false)
  ensure
    prev_o.nil? ? ENV.delete('PLACE_ORDER') : ENV['PLACE_ORDER'] = prev_o
    prev_os.nil? ? ENV.delete('PLACE_ORDERS') : ENV['PLACE_ORDERS'] = prev_os
  end

  it 'lets COINDCX_DRY_RUN override runtime.dry_run from YAML' do
    prev = ENV['COINDCX_DRY_RUN']
    ENV['COINDCX_DRY_RUN'] = '1'
    cfg = described_class.new(minimal_bot_config(runtime: { dry_run: false, journal_path: '/tmp/x.sqlite3' }))
    expect(cfg.dry_run?).to be(true)
  ensure
    prev.nil? ? ENV.delete('COINDCX_DRY_RUN') : ENV['COINDCX_DRY_RUN'] = prev
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
      hwm = cfg.strategy[:hwm_giveback]
      expect(hwm[:enabled]).to be(true)
      expect(hwm[:min_peak_usdt]).to eq(25)
      expect(hwm[:giveback_pct]).to eq(0.5)
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
        COINDCX_TELEGRAM_BOT_TOKEN
        COINDCX_TELEGRAM_CHAT_ID
        COINDCX_TELEGRAM_OPS_CHAT_ID
        COINDCX_TELEGRAM_OPS_BOT_TOKEN
        COINDCX_TELEGRAM_OPS_TYPES
      ]
      saved = keys.to_h { |k| [k, ENV[k]] }
      keys.each { |k| ENV.delete(k) }
      example.run
    ensure
      saved.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    end

    it 'is not ready when env credentials are incomplete' do
      ENV['COINDCX_TELEGRAM_BOT_TOKEN'] = 't'
      cfg = described_class.new(minimal_bot_config)
      expect(cfg.telegram_journal_notifications_ready?).to be(false)
    end

    it 'is ready when bot token and chat id are set' do
      ENV['COINDCX_TELEGRAM_BOT_TOKEN'] = 'secret'
      ENV['COINDCX_TELEGRAM_CHAT_ID'] = '99'
      cfg = described_class.new(minimal_bot_config)
      expect(cfg.telegram_journal_notifications_ready?).to be(true)
    end

    it 'defaults ops duplicate types when COINDCX_TELEGRAM_OPS_TYPES is unset' do
      cfg = described_class.new(minimal_bot_config)
      expect(cfg.telegram_journal_ops_duplicate_types).to eq(%w[open_failed smc_setup_invalidated])
    end

    it 'parses COINDCX_TELEGRAM_OPS_TYPES as a comma-separated list' do
      ENV['COINDCX_TELEGRAM_OPS_TYPES'] = ' a , b '
      cfg = described_class.new(minimal_bot_config)
      expect(cfg.telegram_journal_ops_duplicate_types).to eq(%w[a b])
    end

    it 'treats empty COINDCX_TELEGRAM_OPS_TYPES as no ops duplicate types' do
      ENV['COINDCX_TELEGRAM_OPS_TYPES'] = ''
      cfg = described_class.new(minimal_bot_config)
      expect(cfg.telegram_journal_ops_duplicate_types).to eq([])
    end
  end
end
