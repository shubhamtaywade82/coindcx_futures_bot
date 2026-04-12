# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'faraday'
require 'coindcx'
require 'coindcx_bot/paper_exchange'

RSpec.describe 'PaperExchange Rack app' do
  let(:path) { File.join(Dir.tmpdir, "pe_app_#{Process.pid}_#{rand(1_000_000)}.sqlite3") }
  let(:api_key) { 'test-key' }
  let(:api_secret) { 'test-secret' }
  let(:store) do
    s = CoindcxBot::PaperExchange::Store.new(path)
    CoindcxBot::PaperExchange::Boot.ensure_seed!(s, api_key: api_key, api_secret: api_secret,
                                                   seed_spot_usdt: '0', seed_futures_usdt: '1_000_000')
    s
  end
  let(:fx_stubs) { Faraday::Adapter::Test::Stubs.new }
  let(:fx_conn) do
    Faraday.new(url: 'https://api.coindcx.com') do |f|
      f.adapter :test, fx_stubs
    end
  end
  let(:conversions_feed) do
    fx_stubs.get('/api/v1/derivatives/futures/data/conversions') do
      [
        200,
        { 'Content-Type' => 'application/json' },
        '[{"symbol":"USDTINR","margin_currency_short_name":"INR","target_currency_short_name":"USDT",' \
        '"conversion_price":88.5,"last_updated_at":1}]'
      ]
    end
    CoindcxBot::PaperExchange::ConversionsFeed.new(
      fallback_inr_per_usdt: BigDecimal('83'),
      ttl_seconds: 3600,
      logger: nil,
      faraday: fx_conn,
      api_host: 'https://api.coindcx.com',
      path: '/api/v1/derivatives/futures/data/conversions'
    )
  end
  let(:app) do
    pe_store = store
    ledger = CoindcxBot::PaperExchange::Ledger.new(pe_store)
    fill_engine = CoindcxBot::Execution::FillEngine.new(slippage_bps: 1, fee_bps: 1)
    market_rules = CoindcxBot::PaperExchange::MarketRules.new(pe_store)
    orders = CoindcxBot::PaperExchange::OrdersService.new(
      store: pe_store, ledger: ledger, market_rules: market_rules, fill_engine: fill_engine
    )
    wallets = CoindcxBot::PaperExchange::WalletsService.new(store: pe_store, ledger: ledger)
    positions = CoindcxBot::PaperExchange::PositionsService.new(store: pe_store, ledger: ledger, orders_service: orders)
    tick = CoindcxBot::PaperExchange::TickDispatcher.new(store: pe_store, orders_service: orders)
    inner = CoindcxBot::PaperExchange::App.new(
      wallets: wallets,
      orders: orders,
      positions: positions,
      tick_dispatcher: tick,
      store: pe_store,
      logger: nil,
      conversions_feed: conversions_feed
    )
    Rack::Builder.new do
      use CoindcxBot::PaperExchange::SqlMutex::Middleware, store: pe_store
      use CoindcxBot::PaperExchange::RateLimit::Middleware
      use CoindcxBot::PaperExchange::Auth::Middleware, store: pe_store
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

  it 'returns USDTINR conversions as a JSON array on public GET' do
    env = Rack::MockRequest.env_for('/api/v1/derivatives/futures/data/conversions', method: 'GET')
    status, _, body = app.call(env)
    expect(status).to eq(200)
    j = JSON.parse(body.join)
    expect(j).to be_an(Array)
    expect(j.first['symbol']).to eq('USDTINR')
    expect(j.first['conversion_price']).to eq(88.5)
  end

  it 'returns 401 missing_auth_headers when auth headers are absent' do
    env = Rack::MockRequest.env_for(
      '/exchange/v1/paper/simulation/tick',
      method: 'POST',
      input: '{"pair":"B-SOL_USDT","ltp":"1"}',
      'CONTENT_TYPE' => 'application/json'
    )
    expect do
      status, _, body = app.call(env)
      expect(status).to eq(401)
      expect(JSON.parse(body.join).dig('error', 'code')).to eq('missing_auth_headers')
    end.to output(/paper_exchange:auth.*missing auth headers/).to_stderr
  end

  it 'returns 401 unknown_api_key when api key is not seeded' do
    prev_key = ENV['COINDCX_API_KEY']
    ENV['COINDCX_API_KEY'] = api_key
    signer = CoinDCX::Auth::Signer.new(api_key: 'other-key', api_secret: api_secret)
    normalized, headers = signer.authenticated_request({ pair: 'B-SOL_USDT', ltp: '1' })
    payload = JSON.generate(CoinDCX::Utils::Payload.stringify_keys(normalized))
    env = Rack::MockRequest.env_for(
      '/exchange/v1/paper/simulation/tick',
      method: 'POST',
      input: payload,
      'CONTENT_TYPE' => 'application/json',
      'HTTP_X_AUTH_APIKEY' => headers['X-AUTH-APIKEY'],
      'HTTP_X_AUTH_SIGNATURE' => headers['X-AUTH-SIGNATURE']
    )
    expect do
      status, _, body = app.call(env)
      expect(status).to eq(401)
      j = JSON.parse(body.join)['error']
      expect(j['code']).to eq('unknown_api_key')
      expect(j['hint']).to include('request key')
      expect(j['hint']).to include('server env')
    end.to output(/paper_exchange:auth.*unknown api key/).to_stderr
  ensure
    if prev_key.nil?
      ENV.delete('COINDCX_API_KEY')
    else
      ENV['COINDCX_API_KEY'] = prev_key
    end
  end

  it 'returns 401 invalid_signature when signature does not match body' do
    env = Rack::MockRequest.env_for(
      '/exchange/v1/paper/simulation/tick',
      method: 'POST',
      input: '{"pair":"B-SOL_USDT","ltp":"1","timestamp":1}',
      'CONTENT_TYPE' => 'application/json',
      'HTTP_X_AUTH_APIKEY' => api_key,
      'HTTP_X_AUTH_SIGNATURE' => '0' * 64
    )
    expect do
      status, _, body = app.call(env)
      expect(status).to eq(401)
      expect(JSON.parse(body.join).dig('error', 'code')).to eq('invalid_signature')
    end.to output(/paper_exchange:auth.*invalid signature/).to_stderr
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

  it 'serves public GET instrument without auth (paper skips auth middleware; live client may sign)' do
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
    j = JSON.parse(body.join)
    expect(j).to include('status' => 'ok')
    expect(j['position_exits']).to eq([])
  end

  it 're-seeds pe_api_keys when the row is missing but the request key matches ENV' do
    prev_k = ENV['COINDCX_API_KEY']
    prev_s = ENV['COINDCX_API_SECRET']
    ENV['COINDCX_API_KEY'] = api_key
    ENV['COINDCX_API_SECRET'] = api_secret
    store.db.execute('DELETE FROM pe_api_keys')
    status, _, body = signed_post(
      '/exchange/v1/paper/simulation/tick',
      { pair: 'B-SOL_USDT', ltp: '77' }
    )
    expect(status).to eq(200)
    j = JSON.parse(body.join)
    expect(j).to include('status' => 'ok')
    expect(j['position_exits']).to eq([])
  ensure
    if prev_k.nil?
      ENV.delete('COINDCX_API_KEY')
    else
      ENV['COINDCX_API_KEY'] = prev_k
    end
    if prev_s.nil?
      ENV.delete('COINDCX_API_SECRET')
    else
      ENV['COINDCX_API_SECRET'] = prev_s
    end
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
