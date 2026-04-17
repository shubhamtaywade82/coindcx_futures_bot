# frozen_string_literal: true

require 'logger'

RSpec.describe CoindcxBot::Core::Engine, 'paper_exchange REST routing' do
  around do |example|
    prev_key = ENV['COINDCX_API_KEY']
    prev_sec = ENV['COINDCX_API_SECRET']
    ENV['COINDCX_API_KEY'] = 'test_key'
    ENV['COINDCX_API_SECRET'] = 'test_secret'
    CoinDCX.reset_configuration!
    example.run
  ensure
    prev_key.nil? ? ENV.delete('COINDCX_API_KEY') : ENV['COINDCX_API_KEY'] = prev_key
    prev_sec.nil? ? ENV.delete('COINDCX_API_SECRET') : ENV['COINDCX_API_SECRET'] = prev_sec
    CoinDCX.reset_configuration!
  end

  it 'keeps the global CoinDCX REST base on production when gateway paper exchange is enabled' do
    cfg = CoindcxBot::Config.new(
      minimal_bot_config(
        paper_exchange: { enabled: true, api_base_url: 'http://127.0.0.1:9299' }
      )
    )
    logger = Logger.new(File::NULL)
    engine = described_class.new(config: cfg, logger: logger)

    expect(CoinDCX.configuration.api_base_url).not_to include('127.0.0.1')
    paper_client = engine.instance_variable_get(:@order_account_client)
    expect(paper_client).not_to equal(engine.instance_variable_get(:@client))
    expect(paper_client.configuration.api_base_url).to eq('http://127.0.0.1:9299')
  end

  it 'uses the same client for orders and market data when paper_exchange is off' do
    cfg = CoindcxBot::Config.new(minimal_bot_config)
    logger = Logger.new(File::NULL)
    engine = described_class.new(config: cfg, logger: logger)

    main = engine.instance_variable_get(:@client)
    orders = engine.instance_variable_get(:@order_account_client)
    expect(orders).to equal(main)
  end
end
