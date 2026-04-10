# frozen_string_literal: true

require 'logger'

module CoindcxBot
  class CLI
    def self.start(argv)
      cmd = argv.shift || 'help'
      case cmd
      when 'run'
        run_engine
      when 'tui'
        Tui::App.start
      when 'doctor'
        exit(Doctor.run ? 0 : 1)
      when 'paper-status'
        exit(PaperStatus.run ? 0 : 1)
      when 'help', '--help', '-h'
        help
      else
        warn("Unknown command: #{cmd}")
        help
        exit 1
      end
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
          help          — this message

        Environment: COINDCX_API_KEY, COINDCX_API_SECRET (optional: .env / .env.local in repo root)
        Config: config/bot.yml (see config/bot.yml.example)
        Paper trading: runtime.dry_run or runtime.paper — journals positions, no exchange orders
        CoinDCX-shaped paper exchange: run bin/paper-exchange (see config/bot.yml.example paper_exchange)
      HELP
    end
  end
end
