# frozen_string_literal: true

require 'bigdecimal'
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
        raw_full = {}
        cfg_path = ENV['COINDCX_BOT_CONFIG'] || CoindcxBot::Config::DEFAULT_PATH
        expanded_cfg = File.expand_path(cfg_path)
        if File.file?(expanded_cfg)
          raw_full = YAML.safe_load(File.read(expanded_cfg), permitted_classes: [Symbol], aliases: true) || {}
          paper_cfg = (raw_full['paper'] || raw_full[:paper] || {})
        end
        slippage = paper_cfg.fetch('slippage_bps', 5)
        fee = paper_cfg.fetch('fee_bps', 4)
        fill_engine = CoindcxBot::Execution::FillEngine.new(slippage_bps: slippage, fee_bps: fee)

        market_rules = MarketRules.new(store)
        orders = OrdersService.new(store: store, ledger: ledger, market_rules: market_rules, fill_engine: fill_engine)
        wallets = WalletsService.new(store: store, ledger: ledger)
        positions = PositionsService.new(store: store, ledger: ledger, orders_service: orders)
        tick_dispatcher = TickDispatcher.new(store: store, orders_service: orders)

        inr_fb = BigDecimal((raw_full[:inr_per_usdt] || raw_full['inr_per_usdt'] || 83).to_s)
        fx_ttl = Integer(ENV.fetch('PAPER_EXCHANGE_FX_TTL_SECONDS', '60'))
        fx_host = ENV.fetch('PAPER_EXCHANGE_FX_UPSTREAM_HOST', 'https://api.coindcx.com').to_s.chomp('/')
        fx_path = ENV.fetch('PAPER_EXCHANGE_FX_UPSTREAM_PATH', '/api/v1/derivatives/futures/data/conversions').to_s
        conversions_feed = ConversionsFeed.new(
          fallback_inr_per_usdt: inr_fb,
          ttl_seconds: fx_ttl,
          logger: logger,
          api_host: fx_host,
          path: fx_path
        )

        inner = App.new(
          wallets: wallets,
          orders: orders,
          positions: positions,
          tick_dispatcher: tick_dispatcher,
          store: store,
          logger: logger,
          conversions_feed: conversions_feed
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
