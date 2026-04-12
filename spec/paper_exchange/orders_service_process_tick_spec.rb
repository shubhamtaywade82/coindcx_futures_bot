# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'coindcx_bot/paper_exchange'

RSpec.describe CoindcxBot::PaperExchange::OrdersService, '#process_tick' do
  let(:path) { File.join(Dir.tmpdir, "pe_proc_tick_#{Process.pid}_#{rand(1_000_000)}.sqlite3") }
  let(:api_key) { 'tick-spec-key' }
  let(:api_secret) { 'tick-spec-secret' }
  let(:store) do
    s = CoindcxBot::PaperExchange::Store.new(path)
    CoindcxBot::PaperExchange::Boot.ensure_seed!(s, api_key: api_key, api_secret: api_secret,
                                                   seed_spot_usdt: '0', seed_futures_usdt: '1_000_000')
    s
  end
  let(:ledger) { CoindcxBot::PaperExchange::Ledger.new(store) }
  let(:fill_engine) { CoindcxBot::Execution::FillEngine.new(slippage_bps: 1, fee_bps: 1) }
  let(:market_rules) { CoindcxBot::PaperExchange::MarketRules.new(store) }
  let(:orders) do
    described_class.new(store: store, ledger: ledger, market_rules: market_rules, fill_engine: fill_engine)
  end
  let(:tick_dispatcher) { CoindcxBot::PaperExchange::TickDispatcher.new(store: store, orders_service: orders) }
  let(:user_id) { store.db.get_first_row('SELECT user_id FROM pe_api_keys LIMIT 1')['user_id'].to_i }

  after { FileUtils.rm_f(path) }

  before do
    market_rules.ensure_pair!('B-SOL_USDT')
    store.db.execute(
      'UPDATE pe_market_rules SET allowed_order_types = ? WHERE pair = ?',
      [JSON.generate(%w[market_order limit_order stop_market stop_limit take_profit]), 'B-SOL_USDT']
    )
  end

  it 'returns position_exits with net USDT PnL when a stop_market fully closes a long' do
    tick_dispatcher.dispatch!(user_id, pair: 'B-SOL_USDT', ltp: '100')

    orders.create(
      user_id,
      {
        pair: 'B-SOL_USDT',
        side: 'buy',
        order_type: 'market_order',
        total_quantity: '0.01',
        leverage: 5,
        client_order_id: 'mkt-entry-1'
      }
    )

    orders.create(
      user_id,
      {
        pair: 'B-SOL_USDT',
        side: 'sell',
        order_type: 'stop_market',
        stop_price: '95',
        total_quantity: '0.01',
        leverage: 5,
        client_order_id: 'stop-sl-1'
      }
    )

    res = orders.process_tick(
      user_id,
      pair: 'B-SOL_USDT',
      ltp: BigDecimal('90'),
      high: BigDecimal('91'),
      low: BigDecimal('89')
    )

    expect(res).to be_a(Hash)
    expect(res[:tick_fills].size).to eq(1)
    expect(res[:position_exits].size).to eq(1)

    ex = res[:position_exits].first
    expect(ex[:pair]).to eq('B-SOL_USDT')
    expect(ex[:realized_pnl_usdt]).to be_a(BigDecimal)
    expect(ex[:fill_price]).to be_a(BigDecimal)
    expect(ex[:position_id]).not_to be_nil
    expect(ex[:trigger]).to eq('stop_loss')
  end
end
