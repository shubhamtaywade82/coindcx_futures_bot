# frozen_string_literal: true

require 'logger'

module CoindcxBot
  class CLI
    def self.start(argv)
      argv = Array(argv).dup
      cmd = argv.shift || 'help'
      apply_mode_cli_flags!(argv)
      case cmd
      when 'run'
        run_engine
      when 'tui'
        Tui::App.start
      when 'doctor'
        exit(Doctor.run ? 0 : 1)
      when 'paper-status'
        exit(PaperStatus.run ? 0 : 1)
      when 'smc-setup'
        exit(smc_setup_command(argv) ? 0 : 1)
      when 'regime-backtest'
        exit(regime_backtest(argv) ? 0 : 1)
      when 'help', '--help', '-h'
        help
      else
        warn("Unknown command: #{cmd}")
        help
        exit 1
      end
    end

    def self.apply_mode_cli_flags!(argv)
      last = nil
      argv.delete_if do |a|
        next false unless a == '--scalper' || a == '--swing'

        last = a
        true
      end
      return if last.nil?

      ENV[CoindcxBot::ScalperProfile::ENV_KEY] = last == '--scalper' ? 'scalper' : 'swing'
    end

    def self.smc_setup_command(argv)
      sub = argv.shift || 'status'
      config = Config.load
      case sub
      when 'status'
        smc_setup_print_status(config)
      when 'help', '--help', '-h'
        puts <<~HELP
          bin/bot smc-setup status — print YAML flags + active setups in journal

          When the engine runs with smc_setup.planner_enabled: true, watch logs for:
            [smc_setup:planner] upserted setup_id=... (Ollama → TradeSetup store)

          Regime narrative AI (regime.ai) is separate; it does not populate TradeSetups.
        HELP
        true
      else
        warn("Unknown smc-setup subcommand: #{sub} (try: status)")
        false
      end
    end

    def self.smc_setup_print_status(config)
      puts "smc_setup.enabled: #{config.smc_setup_enabled?}"
      puts "smc_setup.planner_enabled (Ollama → TradeSetup JSON): #{config.smc_setup_planner_enabled?}"
      puts "smc_setup.gatekeeper_enabled: #{config.smc_setup_gatekeeper_enabled?}"
      puts "smc_setup.auto_execute: #{config.smc_setup_auto_execute?}"
      puts "smc_setup.model: #{config.smc_setup_model.inspect}  ollama: #{config.smc_setup_ollama_base_url.inspect}"
      journal = Persistence::Journal.new(config.journal_path)
      rows = journal.smc_setup_load_active
      puts "active trade setups in journal (#{config.journal_path}): #{rows.size}"
      rows.each do |r|
        puts "  #{r[:setup_id]}  #{r[:pair]}  state=#{r[:state]}"
      end
      journal.close
      puts "\nRegime AI (regime.enabled + regime.ai.enabled) is independent — it does not drive smc_setup."
      true
    rescue StandardError => e
      warn e.message
      false
    end

    def self.regime_backtest(argv)
      pair = argv[0]
      logger = Logger.new($stdout)
      config = Config.load
      pair ||= config.pairs.first
      raise 'no pair' if pair.nil? || pair.to_s.strip.empty?

      CoinDCX.configure do |c|
        c.api_key = ENV.fetch('COINDCX_API_KEY').to_s.strip
        c.api_secret = ENV.fetch('COINDCX_API_SECRET').to_s.strip
        c.logger = logger
      end
      client = CoinDCX.client
      md = Gateways::MarketDataGateway.new(
        client: client,
        margin_currency_short_name: config.margin_currency_short_name
      )
      lookback = config.runtime.fetch(:candle_lookback, 200).to_i
      res = config.strategy.fetch(:execution_resolution, '15m').to_s
      mult = Core::Engine.resolution_seconds(res)
      to = Time.now.to_i
      from = to - (lookback * mult)
      candles_res = md.list_candlesticks(pair: pair, resolution: res, from: from, to: to)
      unless candles_res.ok?
        warn("candles: #{candles_res.message}")
        return false
      end

      candles = candles_res.value
      hmm_cfg = config.regime_hmm_hash.merge(config.regime_backtest_section)
      result = Backtest::RegimeWalkForward.run(candles: candles, hmm_config: hmm_cfg)
      puts "pair=#{pair} train=#{result.train_bars} oos=#{result.oos_bars} states=#{result.n_states} BIC=#{result.bic.round(2)} oos_loglik=#{result.log_lik.round(4)}"
      true
    rescue StandardError => e
      warn e.message
      warn e.backtrace.first(5).join("\n")
      false
    end

    def self.run_engine
      logger = Logger.new($stdout)
      logger.level = Logger::INFO
      config = Config.load
      engine = Core::Engine.new(config: config, logger: logger)
      engine.run
    rescue Config::ConfigurationError => e
      warn e.message
      warn 'Copy config/bot.yml.example to config/bot.yml'
      exit 1
    rescue Interrupt
      logger.info('Interrupted.')
    end

    def self.help
      puts <<~HELP
        coindcx_futures_bot — usage: bin/bot <command>

          run     — start trading engine (blocking)
          tui     — engine + TTY dashboard (auto-refresh + single-key commands)
          doctor        — verify credentials and list SOL/ETH futures instruments
          paper-status  — print journal open positions + today's INR PnL + recent paper_realized events
          smc-setup status — SMC TradeSetup flags + active setups in journal (planner is Ollama, not regime.ai)
          regime-backtest [PAIR] — fetch exec candles, walk-forward HMM fit (read-only; no Ollama)
          help          — this message

        Environment: COINDCX_API_KEY, COINDCX_API_SECRET (optional: .env / .env.local in repo root)
        Config: config/bot.yml (see config/bot.yml.example)
        Paper trading: runtime.dry_run or runtime.paper — journals positions, no exchange orders
        CoinDCX-shaped paper exchange: run bin/paper-exchange (see config/bot.yml.example paper_exchange)

        Scalper preset: runtime.mode: scalper in config, or COINDCX_BOT_MODE=scalper, or append --scalper to run/tui.
        Swing (default overlay off): COINDCX_BOT_MODE=swing or --swing (overrides YAML mode).
      HELP
    end
  end
end
