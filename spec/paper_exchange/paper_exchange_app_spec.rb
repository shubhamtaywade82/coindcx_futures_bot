# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'coindcx'
require 'coindcx_bot/paper_exchange'

RSpec.describe 'PaperExchange Rack app' do
  let(:path) { File.join(Dir.tmpdir, "pe_app_#{Process.pid}_#{rand(1_000_000)}.sqlite3") }
  let(:api_key) { 'test-key' }
  let(:api_secret) { 'test-secret' }
  let(:app) do
    store = CoindcxBot::PaperExchange::Store.new(path)
    ledger = CoindcxBot::PaperExchange::Ledger.new(store)
    CoindcxBot::PaperExchange::Boot.ensure_seed!(store, api_key: api_key, api_secret: api_secret,
                                                    seed_spot_usdt: '0', seed_futures_usdt: '1_000_000')
    fill_engine = CoindcxBot::Execution::FillEngine.new(slippage_bps: 1, fee_bps: 1)
    market_rules = CoindcxBot::PaperExchange::MarketRules.new(store)
    orders = CoindcxBot::PaperExchange::OrdersService.new(
      store: store, ledger: ledger, market_rules: market_rules, fill_engine: fill_engine
    )
    wallets = CoindcxBot::PaperExchange::WalletsService.new(store: store, ledger: ledger)
    positions = CoindcxBot::PaperExchange::PositionsService.new(store: store, ledger: ledger, orders_service: orders)
    tick = CoindcxBot::PaperExchange::TickDispatcher.new(store: store, orders_service: orders)
    inner = CoindcxBot::PaperExchange::App.new(
      wallets: wallets,
      orders: orders,
      positions: positions,
      tick_dispatcher: tick,
      store: store,
      logger: nil
    )
    Rack::Builder.new do
      use CoindcxBot::PaperExchange::RateLimit::Middleware
      use CoindcxBot::PaperExchange::Auth::Middleware, store: store
      run inner
    end
  end

  after { FileUtils.rm_f(path) }

  def signed_post(path_s, body_hash)
    signer = CoinDCX::Auth::Signer.new(api_key: api_key, api_secret: api_secret)
    normalized, headers = signer.authenticated_request(body_hash)
    payload = JSON.generate(CoinDCX::Utils::Payload.stringify_keys(normalized))
    env = Rack::MockRequest.env_for(
      path_s,
      method: 'POST',
      input: payload,
      'CONTENT_TYPE' => 'application/json',
      'HTTP_X_AUTH_APIKEY' => headers['X-AUTH-APIKEY'],
      'HTTP_X_AUTH_SIGNATURE' => headers['X-AUTH-SIGNATURE']
    )
    app.call(env)
  end

  it 'returns health without auth' do
    env = Rack::MockRequest.env_for('/health', method: 'GET')
    status, = app.call(env)
    expect(status).to eq(200)
  end

  it 'returns 404 for instrument when mark price is not seeded yet' do
    env = Rack::MockRequest.env_for(
      '/exchange/v1/derivatives/futures/data/instrument?pair=B-SOL_USDT&margin_currency_short_name=USDT',
      method: 'GET'
    )
    status, _, body = app.call(env)
    expect(status).to eq(404)
    j = JSON.parse(body.join)
    expect(j.dig('error', 'code')).to eq('no_mark')
  end

  it 'serves public GET instrument without auth (CoinDCX client uses auth: false)' do
    signed_post('/exchange/v1/paper/simulation/tick', { pair: 'B-SOL_USDT', ltp: '123.45' })
    env = Rack::MockRequest.env_for(
      '/exchange/v1/derivatives/futures/data/instrument?pair=B-SOL_USDT&margin_currency_short_name=USDT',
      method: 'GET'
    )
    status, _, body = app.call(env)
    expect(status).to eq(200)
    j = JSON.parse(body.join)
    expect(j['ltp']).to eq('123.45')
    expect(j['last_traded_price']).to eq('123.45')
    expect(j).to include('bid' => be_a(String), 'ask' => be_a(String))
  end

  it 'accepts a signed simulation tick' do
    status, _, body = signed_post(
      '/exchange/v1/paper/simulation/tick',
      { pair: 'B-SOL_USDT', ltp: '100.5', high: '101', low: '99' }
    )
    expect(status).to eq(200)
    expect(JSON.parse(body.join)).to include('status' => 'ok')
  end

  it 'creates a market order after tick seeds mark price' do
    signed_post('/exchange/v1/paper/simulation/tick', { pair: 'B-SOL_USDT', ltp: '100' })
    status, _, body = signed_post(
      '/exchange/v1/derivatives/futures/orders/create',
      {
        order: {
          pair: 'B-SOL_USDT',
          side: 'buy',
          order_type: 'market_order',
          total_quantity: '0.01',
          leverage: 5,
          client_order_id: 'cid-1'
        }
      }
    )
    expect(status).to eq(200)
    parsed = JSON.parse(body.join)
    expect(parsed['status']).to eq('filled')
  end
end
