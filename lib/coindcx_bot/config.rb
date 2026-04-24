# frozen_string_literal: true

require 'bigdecimal'
require 'yaml'
require_relative 'scalper_profile'

module CoindcxBot
  class Config
    DEFAULT_PATH = File.expand_path('../../config/bot.yml', __dir__)

    # Upper bound for `pairs:` (WS subs, REST poll, and TUI rows scale with count).
    MAX_PAIRS = 32

    attr_reader :raw

    def self.scalper_mode_requested?(raw_hash)
      env = ENV[ScalperProfile::ENV_KEY].to_s.strip.downcase
      return false if %w[swing default].include?(env)
      return true if env == 'scalper'

      raw_hash.dig(:runtime, :mode)&.to_s&.strip&.downcase == 'scalper'
    end

    def self.load(path = nil)
      path ||= ENV.fetch('COINDCX_BOT_CONFIG', DEFAULT_PATH)
      expanded = File.expand_path(path)
      raise ConfigurationError, "Missing config: #{expanded}" unless File.file?(expanded)

      new(YAML.safe_load(File.read(expanded), permitted_classes: [Symbol], aliases: true))
    end

    def initialize(hash)
      @raw = deep_symbolize(hash || {})
      @scalper_mode = self.class.scalper_mode_requested?(@raw)
      @raw = deep_merge_defaults(@raw, ScalperProfile::OVERLAY) if @scalper_mode
      validate_whitelist!
      validate_risk_pct_sanity!
      validate_risk_band!
      validate_risk_capital_pct!
      validate_runtime_no_legacy_paper_flag!
      validate_meta_first_win!
      apply_coindcx_env_runtime_overrides!
    end

    def scalper_mode?
      @scalper_mode
    end

    def trading_mode_label
      @scalper_mode ? 'SCALP' : 'SWING'
    end

    def pairs
      Array(raw[:pairs]).map(&:to_s)
    end

    def margin_currency_short_name
      raw[:margin_currency_short_name].to_s
    end

    # Fallback when CoinDCX conversions is disabled or unreachable (see `fx:`).
    def inr_per_usdt
      BigDecimal(raw.fetch(:inr_per_usdt, 83).to_s)
    end

    def fx_section
      s = raw[:fx]
      s.is_a?(Hash) ? s : {}
    end

    # When false, skip HTTP and always use `inr_per_usdt`.
    def fx_enabled?
      sec = fx_section
      return true unless sec.key?(:enabled)

      truthy?(sec[:enabled])
    end

    def fx_ttl_seconds
      v = fx_section.fetch(:ttl_seconds, 60)
      n = Integer(v.to_s)
      n < 5 ? 5 : n
    rescue ArgumentError, TypeError
      60
    end

    # Reference equity in INR (position sizing when `risk.per_trade_capital_pct` is set; TUI header).
    def capital_inr
      v = raw[:capital_inr] || raw['capital_inr']
      return nil if v.nil? || v.to_s.strip.empty?

      BigDecimal(v.to_s)
    rescue ArgumentError, TypeError
      nil
    end

    # True when both INR clamps are set explicitly (legacy YAML). Otherwise clamps scale from `capital_inr`.
    def legacy_per_trade_inr_band?
      rk = risk
      risk_value_present?(rk, :per_trade_inr_min) && risk_value_present?(rk, :per_trade_inr_max)
    end

    # Per-trade floor in INR: explicit `per_trade_inr_min`, else `capital_inr` × min_pct/100, else ₹250.
    def resolved_per_trade_inr_min
      rk = risk
      if risk_value_present?(rk, :per_trade_inr_min)
        BigDecimal(rk[:per_trade_inr_min].to_s)
      elsif (cap = capital_inr)
        p = BigDecimal(rk.fetch(:per_trade_inr_min_pct_of_capital, 0.25).to_s)
        (cap * p / 100).round(2, BigDecimal::ROUND_DOWN)
      else
        BigDecimal('250')
      end
    end

    # Per-trade ceiling in INR: explicit `per_trade_inr_max`, else `capital_inr` × max_pct/100, else ₹500.
    def resolved_per_trade_inr_max
      rk = risk
      if risk_value_present?(rk, :per_trade_inr_max)
        BigDecimal(rk[:per_trade_inr_max].to_s)
      elsif (cap = capital_inr)
        p = BigDecimal(rk.fetch(:per_trade_inr_max_pct_of_capital, 3.0).to_s)
        (cap * p / 100).round(2, BigDecimal::ROUND_DOWN)
      else
        BigDecimal('500')
      end
    end

    # Daily loss halt: explicit `max_daily_loss_inr`, else `capital_inr` × loss_pct/100, else ₹1500.
    def resolved_max_daily_loss_inr
      rk = risk
      if risk_value_present?(rk, :max_daily_loss_inr)
        BigDecimal(rk[:max_daily_loss_inr].to_s)
      elsif (cap = capital_inr)
        p = BigDecimal(rk.fetch(:max_daily_loss_pct_of_capital, 3.5).to_s)
        (cap * p / 100).round(2, BigDecimal::ROUND_DOWN)
      else
        BigDecimal('1500')
      end
    end

    def risk
      raw.fetch(:risk, {})
    end

    def flatten_on_daily_loss_breach?
      truthy?(risk[:flatten_on_daily_loss_breach])
    end

    def pause_after_daily_loss_flatten?
      truthy?(risk[:pause_after_daily_loss_flatten])
    end

    def strategy
      raw.fetch(:strategy, {})
    end

    def strategy_name
      s = strategy[:name]
      (s || 'trend_continuation').to_s
    end

    def meta_first_win_strategy?
      strategy_name == 'meta_first_win'
    end

    def meta_first_win_cooldown_seconds_after_close
      return 0 unless meta_first_win_strategy?

      mf = strategy[:meta_first_win]
      return 0 unless mf.is_a?(Hash)

      v = mf[:cooldown_seconds_after_close]
      return 0 if v.nil?

      Float(v.to_s)
    rescue ArgumentError, TypeError
      0
    end

    def execution
      raw.fetch(:execution, {})
    end

    def runtime
      raw.fetch(:runtime, {})
    end

    def regime_section
      raw.fetch(:regime, {})
    end

    def regime_enabled?
      truthy?(regime_section[:enabled])
    end

    def regime_ai_section
      rs = regime_section
      return {} unless rs.is_a?(Hash)

      rs.fetch(:ai, {})
    end

    def regime_ai_enabled?
      regime_enabled? && truthy?(regime_ai_section[:enabled])
    end

    def regime_ai_model
      ENV['OLLAMA_AGENT_MODEL'] || ENV['OLLAMA_MODEL'] || regime_ai_section[:model].to_s.strip
    end

    def regime_ai_min_interval_seconds
      regime_ai_section.fetch(:min_interval_seconds, 180).to_f
    end

    def regime_ai_timeout_seconds
      regime_ai_section.fetch(:timeout_seconds, 90).to_i
    end

    def regime_ai_bars_per_pair
      n = regime_ai_section.fetch(:bars_per_pair, 24).to_i
      [[n, 8].max, 96].min
    end

    def regime_ai_max_pairs
      n = regime_ai_section.fetch(:max_pairs, 8).to_i
      [[n, 1].max, MAX_PAIRS].min
    end

    def regime_ai_ollama_base_url
      ENV['OLLAMA_BASE_URL'] || regime_ai_section[:ollama_base_url].to_s.strip
    end

    def regime_ai_ollama_api_key
      ENV['OLLAMA_API_KEY'] || ''
    end

    def regime_ai_temperature
      Float(regime_ai_section.fetch(:temperature, 0.15))
    rescue ArgumentError, TypeError
      0.15
    end

    def regime_ai_use_retry_middleware?
      truthy?(regime_ai_section.fetch(:use_retry_middleware, true))
    end

    def regime_ai_retry_attempts
      n = regime_ai_section.fetch(:retry_attempts, 3).to_i
      [[n, 1].max, 8].min
    end

    def regime_ai_include_hmm_context?
      return false unless regime_ai_enabled?

      truthy?(regime_ai_section.fetch(:include_hmm_context, true))
    end

    def regime_ai_mode
      regime_ai_section.fetch(:mode, 'tui_narrative').to_s.strip
    end

    def regime_ai_include_feature_packet?
      return false unless regime_ai_enabled?

      truthy?(regime_ai_section.fetch(:include_feature_packet, false))
    end

    def regime_ai_feature_min_candles
      n = regime_ai_section.fetch(:feature_min_candles, 30).to_i
      [[n, 20].max, 200].min
    end

    def regime_ai_feature_tz_offset_minutes
      regime_ai_section.fetch(:feature_tz_offset_minutes, 0).to_i
    end

    def regime_ai_omit_raw_bars_when_feature_packet?
      return false unless regime_ai_include_feature_packet?

      truthy?(regime_ai_section.fetch(:omit_raw_bars_when_feature_packet, false))
    end

    def smc_setup_section
      raw.fetch(:smc_setup, {})
    end

    def smc_setup_enabled?
      truthy?(smc_setup_section[:enabled])
    end

    def smc_setup_planner_enabled?
      smc_setup_enabled? && truthy?(smc_setup_section.fetch(:planner_enabled, false))
    end

    def smc_setup_planner_interval_seconds
      smc_setup_section.fetch(:planner_interval_seconds, 600).to_f
    end

    def smc_setup_planner_reset_state?
      truthy?(smc_setup_section[:planner_reset_state])
    end

    def smc_setup_gatekeeper_enabled?
      smc_setup_enabled? && truthy?(smc_setup_section[:gatekeeper_enabled])
    end

    def smc_setup_max_active_setups_per_pair
      n = smc_setup_section.fetch(:max_active_setups_per_pair, 3).to_i
      [[n, 1].max, 16].min
    end

    def smc_setup_schema_path
      p = smc_setup_section[:schema_path].to_s.strip
      return File.expand_path('../../config/schemas/smc_trade_setup_v1.json', __dir__) if p.empty?

      File.expand_path(p, Dir.pwd)
    end

    def smc_setup_sweep_consecutive_ticks
      n = smc_setup_section.fetch(:sweep_consecutive_ticks, 1).to_i
      [[n, 1].max, 20].min
    end

    def smc_setup_disable_strategy_entries?
      smc_setup_enabled? && truthy?(smc_setup_section.fetch(:disable_strategy_entries, false))
    end

    def smc_setup_auto_execute?
      smc_setup_enabled? && truthy?(smc_setup_section.fetch(:auto_execute, true))
    end

    def smc_setup_model
      ENV['OLLAMA_AGENT_MODEL'] || ENV['OLLAMA_MODEL'] || smc_setup_section[:model].to_s.strip
    end

    def smc_setup_timeout_seconds
      smc_setup_section.fetch(:timeout_seconds, 60).to_i
    end

    def smc_setup_temperature
      Float(smc_setup_section.fetch(:temperature, 0.1))
    rescue ArgumentError, TypeError
      0.1
    end

    def smc_setup_ollama_base_url
      ENV['OLLAMA_BASE_URL'] || smc_setup_section[:ollama_base_url].to_s.strip
    end

    def smc_setup_ollama_api_key
      ENV['OLLAMA_API_KEY'] || ''
    end

    def smc_setup_use_retry_middleware?
      truthy?(smc_setup_section.fetch(:use_retry_middleware, true))
    end

    def smc_setup_retry_attempts
      n = smc_setup_section.fetch(:retry_attempts, 3).to_i
      [[n, 1].max, 8].min
    end

    def smc_setup_gatekeeper_min_interval_seconds
      smc_setup_section.fetch(:gatekeeper_min_interval_seconds, 45).to_f
    end

    def smc_setup_gatekeeper_include_feature_packet?
      return false unless smc_setup_gatekeeper_enabled?

      truthy?(smc_setup_section.fetch(:gatekeeper_include_feature_packet, false))
    end

    def smc_setup_gatekeeper_feature_min_candles
      n = smc_setup_section.fetch(:gatekeeper_feature_min_candles, 30).to_i
      [[n, 20].max, 200].min
    end

    def smc_setup_gatekeeper_feature_tz_offset_minutes
      smc_setup_section.fetch(:gatekeeper_feature_tz_offset_minutes, 0).to_i
    end

    def smc_setup_planner_include_market_state?
      return false unless smc_setup_planner_enabled?

      truthy?(smc_setup_section.fetch(:planner_include_market_state, true))
    end

    def smc_setup_planner_include_ohlcv_features?
      return false unless smc_setup_planner_enabled?

      truthy?(smc_setup_section.fetch(:planner_include_ohlcv_features, true))
    end

    def smc_setup_planner_min_candles
      n = smc_setup_section.fetch(:planner_min_candles, 30).to_i
      [[n, 20].max, 500].min
    end

    def smc_setup_planner_ohlcv_tail
      n = smc_setup_section.fetch(:planner_ohlcv_tail, 12).to_i
      [[n, 4].max, 48].min
    end

    def smc_setup_planner_tz_offset_minutes
      smc_setup_section.fetch(:planner_tz_offset_minutes, 0).to_i
    end

    def smc_setup_lifecycle_enabled?
      smc_setup_enabled? && truthy?(smc_setup_section.fetch(:lifecycle_enabled, true))
    end

    def regime_hmm_section
      rs = regime_section
      return {} unless rs.is_a?(Hash)

      rs.fetch(:hmm, {})
    end

    def regime_hmm_enabled?
      regime_enabled? && truthy?(regime_hmm_section[:enabled])
    end

    def regime_hmm_hash
      regime_hmm_section
    end

    def regime_hmm_persistence_path_for(pair = nil)
      base = regime_hmm_section.fetch(:persistence_path, './data/regime_hmm.json').to_s
      expanded = File.expand_path(base, Dir.pwd)
      return expanded if pair.nil? || pair.to_s.strip.empty?

      dir = File.dirname(expanded)
      stem = File.basename(expanded, '.*')
      ext = File.extname(expanded)
      ext = '.json' if ext.empty?
      File.join(dir, "#{stem}_#{pair}#{ext}")
    end

    def regime_scope
      regime_hmm_section.fetch(:scope, 'per_pair').to_s.strip.downcase
    end

    def regime_ml_section
      rs = regime_section
      return {} unless rs.is_a?(Hash)

      rs.fetch(:ml, {})
    end

    def regime_ml_enabled?
      regime_enabled? && truthy?(regime_ml_section[:enabled])
    end

    def regime_ml_hash
      regime_ml_section
    end

    def regime_ml_model_path_for(pair = nil)
      base = regime_ml_section.fetch(:model_path, './data/ml_regime_model.json').to_s
      expanded = File.expand_path(base, Dir.pwd)
      scope = regime_ml_section.fetch(:scope, 'global').to_s.strip.downcase
      return expanded if scope == 'global' || pair.nil? || pair.to_s.strip.empty?

      dir = File.dirname(expanded)
      stem = File.basename(expanded, '.*')
      ext = File.extname(expanded)
      ext = '.json' if ext.empty?
      File.join(dir, "#{stem}_#{pair}#{ext}")
    end

    def regime_ml_scope_global?
      regime_ml_section.fetch(:scope, 'global').to_s.strip.downcase == 'global'
    end

    def regime_ml_zscore_lookback
      n = regime_ml_section.fetch(:zscore_lookback, 60).to_i
      [[n, 10].max, 500].min
    end

    def regime_ml_confirm_bars
      n = regime_ml_section.fetch(:confirm_bars, 3).to_i
      [[n, 1].max, 20].min
    end

    def regime_ml_immediate_probability
      v = regime_ml_section.fetch(:immediate_probability, 0.92).to_f
      [[v, 0.51].max, 0.999].min
    end

    # hmm_first: use HMM vol tier when present; else ML tier. ml_first: prefer ML tier when present.
    def regime_ml_tier_precedence
      regime_ml_section.fetch(:tier_precedence, 'hmm_first').to_s.strip.downcase
    end

    def regime_strategy_section
      rs = regime_section
      return {} unless rs.is_a?(Hash)

      rs.fetch(:strategy, {})
    end

    def regime_backtest_section
      raw.fetch(:regime_backtest, {})
    end

    def regime_risk_section
      rs = regime_section
      return {} unless rs.is_a?(Hash)

      rs.fetch(:risk, {})
    end

    def regime_risk_enabled?
      regime_enabled? && truthy?(regime_risk_section[:enabled])
    end

    # Paper trading: no exchange orders or account exits. Use +runtime.dry_run+ only (+true+ = simulated execution).
    def dry_run?
      truthy?(runtime[:dry_run])
    end

    # Live (+dry_run: false+) only: when false, the engine uses live feeds and read-only account APIs but does not
    # place or exit futures orders. Ignored in paper (+dry_run: true+). YAML +runtime.place_orders+; env +PLACE_ORDER+
    # or +PLACE_ORDERS+ overrides when set (true/false/1/0). +PLACE_ORDER+ wins if both are set.
    def place_orders?
      return true if dry_run?

      raw_place = runtime[:place_orders]
      env_place = ENV['PLACE_ORDER'].to_s.strip
      env_place = ENV['PLACE_ORDERS'].to_s.strip if env_place.empty?
      v = env_place.empty? ? raw_place : env_place
      return true if v.nil?

      truthy?(v)
    end

    def paper_config
      raw.fetch(:paper, {})
    end

    # Paper bracket: place a working stop-loss order (in-process PaperBroker). When false, exits
    # rely on strategy / liquidation paths instead of simulated stop fills.
    def paper_place_working_stop?
      v = paper_config[:place_working_stop]
      return true if v.nil?

      truthy?(v)
    end

    # Paper bracket: place a working take-profit limit. When false, TP is strategy-driven only.
    def paper_place_working_take_profit?
      v = paper_config[:place_working_take_profit]
      return true if v.nil?

      truthy?(v)
    end

    # When false, the engine does not enqueue WS tick stop breaches and strategies ignore hard stop exits.
    # Liquidation emergency handling in the engine is unchanged.
    def exit_on_hard_stop?
      sec = raw[:strategy]
      return true unless sec.is_a?(Hash)

      v = sec.fetch(:exit_on_hard_stop, true)
      !(v == false || v.to_s.strip.casecmp('false').zero? || v.to_s.strip == '0')
    end

    def paper_exchange_enabled?
      dry_run? && truthy?(raw.dig(:paper_exchange, :enabled))
    end

    def paper_exchange_api_base
      raw.dig(:paper_exchange, :api_base_url).to_s.strip
    end

    def paper_exchange_tick_path
      p = raw.dig(:paper_exchange, :tick_path).to_s.strip
      p.empty? ? '/exchange/v1/paper/simulation/tick' : p
    end

    def journal_path
      File.expand_path(runtime.fetch(:journal_path, './data/bot_journal.sqlite3'), Dir.pwd)
    end

    # Cross-pair correlation groups: array-of-arrays from `risk.correlation_groups`.
    # Each inner array is a set of pair strings that share directional exposure.
    # Default: empty (no correlation gating).
    def correlation_groups
      raw_groups = risk.fetch(:correlation_groups, [])
      return [] unless raw_groups.is_a?(Array)

      raw_groups.filter_map do |g|
        next unless g.is_a?(Array)

        g.map(&:to_s).reject(&:empty?)
      end.reject(&:empty?)
    end

    # On startup, compare journal open positions against the live exchange and close orphans.
    # Opt-in only: `runtime.reconcile_on_startup: true`.
    def reconcile_on_startup?
      truthy?(runtime[:reconcile_on_startup])
    end

    # Periodic runtime reconciliation: re-check journal positions against the exchange
    # during a live session (not only at startup). Opt-in via `runtime.runtime_reconcile: true`.
    def runtime_reconcile_enabled?
      truthy?(runtime[:runtime_reconcile])
    end

    def runtime_reconcile_interval_seconds
      v = runtime.fetch(:runtime_reconcile_interval_seconds, 300).to_i
      v < 30 ? 30 : v
    rescue ArgumentError, TypeError
      300
    end

    # Funding rate estimation for live open positions (every 8 h).
    # Enable with `risk.track_funding_rate: true`.
    def track_funding_rate?
      truthy?(risk[:track_funding_rate])
    end

    # Safety buffer applied to available margin before allowing new entries (%).
    # A 20% buffer means only 80% of available margin can be consumed.
    def margin_safety_buffer_pct
      v = risk.fetch(:margin_safety_buffer_pct, 20).to_f
      [[v, 0].max, 50].min
    rescue ArgumentError, TypeError
      20.0
    end

    # Block new entries when used_margin / equity exceeds this threshold (%).
    def max_margin_ratio_pct
      v = risk.fetch(:max_margin_ratio_pct, 80).to_f
      [[v, 10].max, 100].min
    rescue ArgumentError, TypeError
      80.0
    end

    # Log a warning when liquidation is within this % of mark price.
    def liquidation_alert_pct
      v = risk.fetch(:liquidation_alert_pct, 5).to_f
      [[v, 1].max, 20].min
    rescue ArgumentError, TypeError
      5.0
    end

    # Emergency-close threshold: force-close when liquidation is within this % of mark price.
    def emergency_close_pct
      v = risk.fetch(:emergency_close_pct, 2).to_f
      [[v, 0.5].max, 10].min
    rescue ArgumentError, TypeError
      2.0
    end

    # CoinDCX futures taker fee in basis points (default 5 bps = 0.05 %).
    def taker_fee_bps
      v = risk.fetch(:taker_fee_bps, 5).to_f
      [v, 0].max
    rescue ArgumentError, TypeError
      5.0
    end

    # Estimated per-8h funding rate in basis points (default 1 bps = 0.01 %).
    # Longs pay this; shorts receive it. Used when real-time rate is not fetched.
    def default_funding_rate_bps
      v = risk.fetch(:default_funding_rate_bps, 1).to_f
      v < 0 ? 0 : v
    rescue ArgumentError, TypeError
      1.0
    end

    # Maximum reconnect attempts before the WS loop gives up (0 = unlimited).
    def ws_reconnect_attempts
      v = runtime.fetch(:ws_reconnect_attempts, 5).to_i
      v.negative? ? 5 : v
    end

    # Base delay (seconds) for exponential backoff between WS reconnects.
    def ws_reconnect_base_seconds
      f = Float(runtime.fetch(:ws_reconnect_base_seconds, 3.0))
      f < 0.5 ? 0.5 : f
    rescue ArgumentError, TypeError
      3.0
    end

    # Read-only TUI: poll CoinDCX futures positions (list only — no orders/exits).
    def tui_exchange_positions_enabled?
      truthy?(runtime[:tui_exchange_positions])
    end

    def tui_exchange_positions_refresh_seconds
      v = runtime[:tui_exchange_positions_refresh_seconds]
      f = Float(v.nil? ? 25 : v.to_s)
      f < 5.0 ? 5.0 : f
    rescue ArgumentError, TypeError
      25.0
    end

    # When true (live only): TUI execution grid + header balance/unrealized mirror CoinDCX account data
    # (+futures wallet) instead of journal-only rows. Auto-on when +place_orders?+ is false (observe mode).
    # Optional explicit +runtime.tui_exchange_mirror: true+ when placing live orders but showing exchange rows.
    def tui_exchange_mirror?
      return false if dry_run?
      return false unless tui_exchange_positions_enabled?

      return true unless place_orders?

      truthy?(runtime[:tui_exchange_mirror])
    end

    # Body filter for POST /derivatives/futures/positions (CoinDCX often needs this to return rows).
    def tui_exchange_positions_margin_currencies
      m = runtime[:tui_exchange_positions_margins]
      if m.is_a?(Array) && m.any?
        return m.map { |x| x.to_s.strip.upcase }.reject(&:empty?)
      end

      single = margin_currency_short_name.to_s.strip.upcase
      return [single] unless single.empty?

      %w[USDT INR]
    end

    # Optional Telegram mirror of +Journal#log_event+ rows (+Notifications::TelegramJournalSink+).
    # All switches and IDs are ENV-only (no bot.yml +notifications+ block):
    #   COINDCX_TELEGRAM_BOT_TOKEN, COINDCX_TELEGRAM_CHAT_ID — required to enable
    #   COINDCX_TELEGRAM_OPS_CHAT_ID, COINDCX_TELEGRAM_OPS_BOT_TOKEN — optional second destination
    #   COINDCX_TELEGRAM_OPS_TYPES — comma-separated +event_log+ +type+ names for ops duplicate (default below)
    def telegram_journal_notifications_ready?
      !telegram_journal_bot_token.empty? && !telegram_journal_chat_id.empty?
    end

    def telegram_journal_bot_token
      ENV['COINDCX_TELEGRAM_BOT_TOKEN'].to_s.strip
    end

    def telegram_journal_chat_id
      ENV['COINDCX_TELEGRAM_CHAT_ID'].to_s.strip
    end

    def telegram_journal_ops_bot_token
      t = ENV['COINDCX_TELEGRAM_OPS_BOT_TOKEN'].to_s.strip
      t.empty? ? telegram_journal_bot_token : t
    end

    def telegram_journal_ops_chat_id
      ENV['COINDCX_TELEGRAM_OPS_CHAT_ID'].to_s.strip
    end

    # When +COINDCX_TELEGRAM_OPS_CHAT_ID+ is set, these +event_log+ +type+ values are also sent there.
    # +COINDCX_TELEGRAM_OPS_TYPES+ comma list; unset → defaults; set to empty string → no ops duplicates.
    def telegram_journal_ops_duplicate_types
      raw = ENV['COINDCX_TELEGRAM_OPS_TYPES']
      return %w[open_failed smc_setup_invalidated] if raw.nil?

      raw.to_s.split(',').map(&:strip).reject(&:empty?)
    end

    # --- Multi-level analysis alerts (journal + optional Telegram filter) ---

    def alerts_section
      s = raw[:alerts]
      s.is_a?(Hash) ? s.transform_keys(&:to_sym) : {}
    end

    def alerts_analysis_section
      s = alerts_section[:analysis]
      s.is_a?(Hash) ? s.transform_keys(&:to_sym) : {}
    end

    def alerts_filter_telegram?
      truthy?(alerts_section[:filter_telegram])
    end

    def alerts_analysis_strategy_transitions?
      truthy?(alerts_analysis_section[:strategy_transitions])
    end

    def alerts_analysis_regime_hmm_transitions?
      truthy?(alerts_analysis_section[:regime_hmm_transitions])
    end

    def alerts_analysis_regime_ai_updates?
      truthy?(alerts_analysis_section[:regime_ai_updates])
    end

    def alerts_regime_ai_min_probability_delta
      v = alerts_analysis_section[:regime_ai_min_probability_delta]
      return 10.0 if v.nil? || v.to_s.strip.empty?

      Float(v.to_s)
    rescue ArgumentError, TypeError
      10.0
    end

    # Minimum seconds between +analysis_price_cross+ journal rows for the same pair and rule id
    # (LTP can chop across a level on every WS tick).
    def alerts_analysis_price_cross_cooldown_seconds
      v = alerts_analysis_section[:price_cross_cooldown_seconds]
      return 0.0 if v.nil? || v.to_s.strip.empty?

      Float(v.to_s)
    rescue ArgumentError, TypeError
      0.0
    end

    def alerts_price_rules
      Array(alerts_section[:price_rules]).select { |r| r.is_a?(Hash) }
    end

    def alerts_telegram_config
      h = alerts_section[:telegram] || alerts_section['telegram']
      h.is_a?(Hash) ? h.transform_keys(&:to_sym) : {}
    end

    def alerts_telegram_allow_types
      v = alerts_telegram_config[:allow_types]
      return nil if v.nil?

      Array(v).map(&:to_s).reject(&:empty?)
    end

    def alerts_telegram_critical_types
      v = alerts_telegram_config[:critical_types]
      return default_alerts_critical_types if v.nil?

      Array(v).map(&:to_s).reject(&:empty?)
    end

    def alerts_telegram_default_throttle_seconds
      v = alerts_telegram_config[:default_throttle_seconds]
      return 0.0 if v.nil? || v.to_s.strip.empty?

      Float(v.to_s)
    rescue ArgumentError, TypeError
      0.0
    end

    def alerts_telegram_throttle_by_type
      raw = alerts_telegram_config[:throttle_by_type]
      return {} unless raw.is_a?(Hash)

      raw.transform_keys(&:to_s).each_with_object({}) do |(k, v), acc|
        acc[k] = Float(v.to_s)
      rescue ArgumentError, TypeError
        acc[k] = 0.0
      end
    end

    def alerts_telegram_critical_throttle_seconds
      v = alerts_telegram_config[:critical_throttle_seconds]
      return 30.0 if v.nil? || v.to_s.strip.empty?

      Float(v.to_s)
    rescue ArgumentError, TypeError
      30.0
    end

    def default_alerts_critical_types
      %w[
        open_failed
        signal_close
        analysis_liquidation_proximity
        flatten
      ]
    end

    class ConfigurationError < StandardError; end

    private

    # Startup helpers (+bin/start-dry-run+, +bin/start-live+; both always run +bin/bot tui+): overrides +runtime.dry_run+ from YAML.
    def apply_coindcx_env_runtime_overrides!
      v = ENV['COINDCX_DRY_RUN'].to_s.strip
      return if v.empty?

      @raw[:runtime] ||= {}
      @raw[:runtime][:dry_run] = truthy?(v)
    end

    # Fills in missing keys only (user YAML always wins on explicit keys).
    def deep_merge_defaults(base, defaults)
      return base if defaults.nil? || defaults.empty?

      b = base.is_a?(Hash) ? base.dup : {}
      defaults.each do |k, dv|
        if dv.is_a?(Hash) && b[k].is_a?(Hash)
          b[k] = deep_merge_defaults(b[k], dv)
        elsif !b.key?(k)
          b[k] = dv
        end
      end
      b
    end

    def truthy?(v)
      v == true || v.to_s.downcase == 'true' || v.to_s == '1'
    end

    def risk_value_present?(rk, key)
      rk.key?(key) && !(rk[key].nil? || rk[key].to_s.strip.empty?)
    end

    def validate_whitelist!
      allowed = pairs.uniq
      unless allowed.size.between?(1, MAX_PAIRS)
        raise ConfigurationError,
              "config pairs must list 1–#{MAX_PAIRS} instruments (got #{allowed.size})"
      end

      allowed.each do |p|
        raise ConfigurationError, "Invalid pair #{p.inspect}" unless p.match?(/\A[A-Z0-9._-]+\z/i)
      end
    end

    def validate_risk_band!
      min_r = resolved_per_trade_inr_min
      max_r = resolved_per_trade_inr_max
      return if min_r <= max_r

      raise ConfigurationError,
            'resolved per-trade INR min must be <= max (check capital_inr and risk.*_pct_of_capital or per_trade_inr_min/max)'
    end

    def validate_risk_pct_sanity!
      rk = raw[:risk] || {}
      min_p = BigDecimal(rk.fetch(:per_trade_inr_min_pct_of_capital, 0.25).to_s)
      max_p = BigDecimal(rk.fetch(:per_trade_inr_max_pct_of_capital, 3.0).to_s)
      return if min_p <= max_p

      raise ConfigurationError,
            'risk.per_trade_inr_min_pct_of_capital must be <= risk.per_trade_inr_max_pct_of_capital'

    rescue ArgumentError, TypeError
      raise ConfigurationError, 'risk per-trade *_pct_of_capital values must be numeric'
    end

    def validate_risk_capital_pct!
      rk = raw[:risk] || {}
      return unless risk_value_present?(rk, :per_trade_capital_pct)

      pct = BigDecimal(rk[:per_trade_capital_pct].to_s)
      raise ConfigurationError, 'risk.per_trade_capital_pct must be > 0' unless pct.positive?
      raise ConfigurationError, 'risk.per_trade_capital_pct must be <= 100' if pct > 100

      return unless capital_inr.nil?

      raise ConfigurationError, 'capital_inr is required when risk.per_trade_capital_pct is set'
    end

    def validate_runtime_no_legacy_paper_flag!
      r = raw[:runtime]
      return unless r.is_a?(Hash)
      return unless r.key?(:paper)

      raise ConfigurationError,
            'Remove runtime.paper from bot.yml; use runtime.dry_run only (true = paper trading, false = live).'
    end

    ALLOWED_META_FIRST_WIN_CHILDREN = %w[trend_continuation supertrend_profit smc_confluence].freeze

    def validate_meta_first_win!
      return unless meta_first_win_strategy?

      mf = strategy[:meta_first_win]
      unless mf.is_a?(Hash)
        raise ConfigurationError,
              'strategy.name meta_first_win requires strategy.meta_first_win (hash with children:)'
      end

      kids = mf[:children]
      unless kids.is_a?(Array) && kids.any?
        raise ConfigurationError, 'meta_first_win requires non-empty strategy.meta_first_win.children'
      end

      kids.each_with_index do |ch, i|
        unless ch.is_a?(Hash)
          raise ConfigurationError, "meta_first_win.children[#{i}] must be a Hash"
        end

        chs = ch.transform_keys(&:to_sym)
        n = (chs[:name] || chs[:lane]).to_s.strip
        if n.empty?
          raise ConfigurationError, "meta_first_win.children[#{i}] needs name: (strategy lane for exits)"
        end

        next if ALLOWED_META_FIRST_WIN_CHILDREN.include?(n)

        raise ConfigurationError,
              "meta_first_win.children[#{i}] unsupported name #{n.inspect} " \
              "(allowed: #{ALLOWED_META_FIRST_WIN_CHILDREN.join(', ')})"
      end
    end

    def deep_symbolize(obj)
      case obj
      when Hash
        obj.each_with_object({}) { |(k, v), h| h[k.to_sym] = deep_symbolize(v) }
      when Array
        obj.map { |e| deep_symbolize(e) }
      else
        obj
      end
    end
  end
end
