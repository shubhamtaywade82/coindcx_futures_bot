# frozen_string_literal: true

require 'logger'
require 'yaml'
require 'rack/common_logger'

require_relative '../config'
require_relative '../execution/fill_engine'
require_relative 'sql_mutex'

module CoindcxBot
  module PaperExchange
    module Harness
      module_function

      # Stable default: repo root `data/paper_exchange.sqlite3` (same file no matter the process cwd).
      def default_sqlite_path
        root = File.expand_path('../../..', __dir__)
        File.join(root, 'data', 'paper_exchange.sqlite3')
      end

      # Apache-style lines to stdout (method, path, status, length, duration). Disable: PAPER_EXCHANGE_ACCESS_LOG=0
      def access_log_enabled?
        v = ENV.fetch('PAPER_EXCHANGE_ACCESS_LOG', '1').to_s.strip.downcase
        !%w[0 false no off].include?(v)
      end

      def build_app(logger: nil)
        logger ||= Logger.new($stdout)
        logger.progname = 'paper_exchange'
        logger.level = Logger::INFO
        db_path = ENV['PAPER_EXCHANGE_DB'].to_s.strip
        db_path = default_sqlite_path if db_path.empty?
        db_path = File.expand_path(db_path)
        logger.info("[paper_exchange] sqlite #{db_path}")

        store = Store.new(db_path)
        ledger = Ledger.new(store)
        api_key = Store.normalize_api_key(ENV.fetch('COINDCX_API_KEY'))
        api_secret = ENV.fetch('COINDCX_API_SECRET').to_s.strip
        Boot.ensure_seed!(store, api_key: api_key, api_secret: api_secret)
        logger.info("[paper_exchange] COINDCX_API_KEY fingerprint=#{Auth.key_fingerprint(api_key)} — bot must use the same key")

        paper_cfg = {}
        cfg_path = ENV['COINDCX_BOT_CONFIG'] || CoindcxBot::Config::DEFAULT_PATH
        if File.file?(File.expand_path(cfg_path))
          raw = YAML.safe_load(File.read(File.expand_path(cfg_path)), permitted_classes: [Symbol], aliases: true) || {}
          paper_cfg = (raw['paper'] || raw[:paper] || {})
        end
        slippage = paper_cfg.fetch('slippage_bps', 5)
        fee = paper_cfg.fetch('fee_bps', 4)
        fill_engine = CoindcxBot::Execution::FillEngine.new(slippage_bps: slippage, fee_bps: fee)

        market_rules = MarketRules.new(store)
        orders = OrdersService.new(store: store, ledger: ledger, market_rules: market_rules, fill_engine: fill_engine)
        wallets = WalletsService.new(store: store, ledger: ledger)
        positions = PositionsService.new(store: store, ledger: ledger, orders_service: orders)
        tick_dispatcher = TickDispatcher.new(store: store, orders_service: orders)

        inner = App.new(
          wallets: wallets,
          orders: orders,
          positions: positions,
          tick_dispatcher: tick_dispatcher,
          store: store,
          logger: logger
        )

        Rack::Builder.new do
          # Outermost: one in-flight request at a time against SQLite (WEBrick is concurrent).
          use SqlMutex::Middleware, store: store
          use Rack::CommonLogger, $stdout if CoindcxBot::PaperExchange::Harness.access_log_enabled?
          use RateLimit::Middleware
          use Auth::Middleware, store: store
          run inner
        end
      end
    end
  end
end
