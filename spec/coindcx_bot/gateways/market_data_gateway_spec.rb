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
end
