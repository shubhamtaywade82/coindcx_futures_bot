# frozen_string_literal: true

require 'coindcx'

RSpec.describe CoindcxBot::Fx::UsdtInrRate do
  let(:config) { CoindcxBot::Config.new(minimal_bot_config.merge(inr_per_usdt: 77)) }
  let(:logger) { instance_double(Logger, warn: nil) }
  let(:futures_md) { instance_double(CoinDCX::REST::Futures::MarketData) }
  let(:futures_facade) { instance_double(CoinDCX::REST::Futures::Facade, market_data: futures_md) }
  let(:client) { instance_double(CoinDCX::Client, futures: futures_facade) }

  let(:sample_row) do
    {
      'symbol' => 'USDTINR',
      'margin_currency_short_name' => 'INR',
      'target_currency_short_name' => 'USDT',
      'conversion_price' => 89.25,
      'last_updated_at' => 1
    }
  end

  describe '.inr_per_usdt_from_conversions_body' do
    it 'returns BigDecimal from USDTINR row' do
      v = described_class.inr_per_usdt_from_conversions_body([sample_row])
      expect(v).to eq(BigDecimal('89.25'))
    end

    it 'returns nil when array is empty' do
      expect(described_class.inr_per_usdt_from_conversions_body([])).to be_nil
    end
  end

  describe '#inr_per_usdt' do
    it 'returns fetched conversion_price when API succeeds' do
      allow(futures_md).to receive(:conversions).and_return([sample_row])
      rate = described_class.new(client: client, config: config, logger: logger)
      expect(rate.inr_per_usdt).to eq(BigDecimal('89.25'))
    end

    it 'returns config fallback when API returns no USDTINR row' do
      allow(futures_md).to receive(:conversions).and_return([{ 'symbol' => 'OTHER' }])
      rate = described_class.new(client: client, config: config, logger: logger)
      expect(rate.inr_per_usdt).to eq(BigDecimal('77'))
    end

    it 'returns config fallback when fx.enabled is false without calling client' do
      off = CoindcxBot::Config.new(minimal_bot_config.merge(inr_per_usdt: 80, fx: { enabled: false }))
      rate = described_class.new(client: client, config: off, logger: logger)
      expect(futures_md).not_to receive(:conversions)
      expect(rate.inr_per_usdt).to eq(BigDecimal('80'))
    end

    it 'does not refetch within ttl' do
      t0 = 100.0
      clock = proc { t0 }
      allow(futures_md).to receive(:conversions).and_return([sample_row])
      rate = described_class.new(client: client, config: config, logger: logger, clock: clock)
      rate.inr_per_usdt
      allow(futures_md).to receive(:conversions).and_raise('should not be called')
      expect(rate.inr_per_usdt).to eq(BigDecimal('89.25'))
    end

    it 'refetches after ttl' do
      t = 100.0
      clock = proc { t }
      allow(futures_md).to receive(:conversions).and_return(
        [sample_row.merge('conversion_price' => 90)],
        [sample_row.merge('conversion_price' => 91)]
      )
      rate = described_class.new(client: client, config: config, logger: logger, clock: clock)
      expect(rate.inr_per_usdt).to eq(BigDecimal('90'))
      t += 61
      expect(rate.inr_per_usdt).to eq(BigDecimal('91'))
    end
  end
end
