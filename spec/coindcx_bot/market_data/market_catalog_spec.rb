# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'sqlite3'
require 'coindcx_bot/persistence/migrations'
require 'coindcx_bot/market_data/market_catalog'

module MarketCatalogSpecFakes
  Client = Struct.new(:public)
  Public = Struct.new(:market_data)
  MarketData = Struct.new(:list_market_details)
end

RSpec.describe CoindcxBot::MarketData::MarketCatalog do
  let(:tmp_dir) { Dir.mktmpdir('market_catalog_spec') }
  let(:db_path) { File.join(tmp_dir, 'test.sqlite3') }
  let(:fake_clock) { Time.utc(2026, 1, 1, 12, 0, 0) }
  let(:clock) { -> { fake_clock } }
  let(:client) do
    MarketCatalogSpecFakes::Client.new(
      MarketCatalogSpecFakes::Public.new(
        MarketCatalogSpecFakes::MarketData.new(market_payload)
      )
    )
  end
  let(:market_payload) do
    [
      {
        'pair' => 'B-BTC_USDT',
        'symbol' => 'BTCUSDT',
        'ecode' => 'B',
        'base_currency_short_name' => 'USDT',
        'target_currency_short_name' => 'BTC',
        'step' => '0.01',
        'min_quantity' => '0.001',
        'min_notional' => '5',
        'max_leverage' => '20',
      },
      {
        'pair' => 'B-ETH_USDT',
        'symbol' => 'ETHUSDT',
        'ecode' => 'B',
        'base_currency_short_name' => 'USDT',
        'target_currency_short_name' => 'ETH',
        'step' => '0.05',
        'min_quantity' => '0.01',
        'min_notional' => '5',
        'max_leverage' => '10',
      },
    ]
  end

  before { CoindcxBot::Persistence::Migrations.runner_for(db_path: db_path).run! }
  after { FileUtils.remove_entry(tmp_dir) }

  describe '#refresh!' do
    it 'fetches and persists market rows' do
      catalog = described_class.new(db_path: db_path, client: client, clock: clock)

      count = catalog.refresh!

      expect(count).to eq(2)
      btc = catalog.lookup(pair: 'B-BTC_USDT')
      expect(btc).to include(
        symbol: 'BTCUSDT',
        max_leverage: 20,
        price_step: '0.01',
        qty_step: '0.001',
        min_notional: '5.0'
      )
    end

    it 'is idempotent — second refresh updates rather than duplicates' do
      catalog = described_class.new(db_path: db_path, client: client, clock: clock)
      catalog.refresh!
      catalog.refresh!

      expect(catalog.all.size).to eq(2)
    end

    it 'preserves the raw response in meta JSON' do
      catalog = described_class.new(db_path: db_path, client: client, clock: clock)
      catalog.refresh!

      meta = JSON.parse(catalog.lookup(pair: 'B-BTC_USDT')[:meta])
      expect(meta['symbol']).to eq('BTCUSDT')
      expect(meta['min_quantity']).to eq('0.001')
    end
  end

  describe '#stale?' do
    it 'returns true when the table is empty' do
      catalog = described_class.new(db_path: db_path, client: client, clock: clock)

      expect(catalog.stale?).to be(true)
    end

    it 'returns false right after a refresh' do
      catalog = described_class.new(db_path: db_path, client: client, clock: clock)
      catalog.refresh!

      expect(catalog.stale?).to be(false)
    end

    it 'returns true after the configured TTL has elapsed' do
      catalog = described_class.new(db_path: db_path, client: client, clock: clock)
      catalog.refresh!

      future_clock = Time.utc(2026, 1, 3, 12, 0, 0) # +48h
      stale_catalog = described_class.new(db_path: db_path, client: client, clock: -> { future_clock })

      expect(stale_catalog.stale?(ttl_seconds: 24 * 60 * 60)).to be(true)
    end
  end

  describe '#lookup' do
    it 'returns nil when the pair is missing' do
      catalog = described_class.new(db_path: db_path, client: client, clock: clock)

      expect(catalog.lookup(pair: 'B-MISSING_USDT')).to be_nil
    end
  end
end
