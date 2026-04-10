# frozen_string_literal: true

require 'logger'
require 'yaml'

module CoindcxBot
  module PaperExchange
    module Harness
      module_function

      def build_app(logger: nil)
        logger ||= Logger.new($stdout)
        db_path = ENV.fetch('PAPER_EXCHANGE_DB') do
          File.expand_path('data/paper_exchange.sqlite3', Dir.pwd)
        end

        store = Store.new(db_path)
        ledger = Ledger.new(store)
        api_key = ENV.fetch('COINDCX_API_KEY')
        api_secret = ENV.fetch('COINDCX_API_SECRET')
        Boot.ensure_seed!(store, api_key: api_key, api_secret: api_secret)

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

        inner = App.new(wallets: wallets, orders: orders, positions: positions, tick_dispatcher: tick_dispatcher,
                        logger: logger)

        Rack::Builder.new do
          use RateLimit::Middleware
          use Auth::Middleware, store: store
          run inner
        end
      end
    end
  end
end
