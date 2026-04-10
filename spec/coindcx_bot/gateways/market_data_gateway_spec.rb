# frozen_string_literal: true

RSpec.describe CoindcxBot::Gateways::MarketDataGateway do
  let(:futures_md) { instance_double(CoinDCX::REST::Futures::MarketData) }
  let(:client) { instance_double(CoinDCX::Client) }
  let(:gateway) { described_class.new(client: client, margin_currency_short_name: 'USDT') }

  before do
    allow(client).to receive_message_chain(:futures, :market_data).and_return(futures_md)
  end

  describe '#fetch_instrument_display_quote' do
    it 'returns price and change from flat instrument attributes' do
      inst = CoinDCX::Models::Instrument.new('last_traded_price' => '100.5', 'pc' => '1.2')
      allow(futures_md).to receive(:fetch_instrument).with(
        pair: 'B-SOL_USDT',
        margin_currency_short_name: 'USDT'
      ).and_return(inst)

      res = gateway.fetch_instrument_display_quote(pair: 'B-SOL_USDT')
      expect(res.ok?).to be true
      expect(res.value[:price]).to eq(BigDecimal('100.5'))
      expect(res.value[:change_pct]).to eq(BigDecimal('1.2'))
    end

    it 'merges nested data hash for price keys' do
      inst = CoinDCX::Models::Instrument.new('data' => { 'ltp' => '200.25' })
      allow(futures_md).to receive(:fetch_instrument).and_return(inst)

      res = gateway.fetch_instrument_display_quote(pair: 'B-ETH_USDT')
      expect(res.ok?).to be true
      expect(res.value[:price]).to eq(BigDecimal('200.25'))
    end

    it 'fails validation when no price key is present' do
      inst = CoinDCX::Models::Instrument.new('symbol' => 'B-X')
      allow(futures_md).to receive(:fetch_instrument).and_return(inst)

      res = gateway.fetch_instrument_display_quote(pair: 'B-X')
      expect(res.failure?).to be true
      expect(res.code).to eq(:validation)
    end
  end

  describe '#fetch_futures_rt_quotes' do
    before { allow(client).to receive(:ws).and_return(Object.new) }

    it 'returns ls and pc from the public current_prices futures/rt shape' do
      payload = {
        'ts' => 1,
        'prices' => {
          'B-SOL_USDT' => { 'ls' => '83.28', 'pc' => '0.08' },
          'B-ETH_USDT' => { 'ls' => '2195.27', 'pc' => '-0.1' }
        }
      }
      allow(futures_md).to receive(:current_prices).and_return(payload)

      res = gateway.fetch_futures_rt_quotes(pairs: %w[B-SOL_USDT B-ETH_USDT])
      expect(res.ok?).to be true
      expect(res.value['B-SOL_USDT'][:price]).to eq(BigDecimal('83.28'))
      expect(res.value['B-SOL_USDT'][:change_pct]).to eq(BigDecimal('0.08'))
      expect(res.value['B-ETH_USDT'][:change_pct]).to eq(BigDecimal('-0.1'))
    end
  end
end
