# frozen_string_literal: true

RSpec.describe CoindcxBot::Gateways::WsGateway do
  describe '#normalize_tick (private)' do
    let(:client) { instance_double(CoinDCX::Client, ws: nil) }
    let(:gateway) { described_class.new(client: client) }

    it 'uses instrument when symbol field is absent' do
      tick = gateway.send(:normalize_tick, 'B-SOL_USDT', { 'p' => '123.45' })
      expect(tick.pair).to eq('B-SOL_USDT')
    end

    it 'keys by subscribed instrument even when payload s differs' do
      tick = gateway.send(:normalize_tick, 'B-SOL_USDT', { 'p' => '1', 's' => 'B-ETH_USDT' })
      expect(tick.pair).to eq('B-SOL_USDT')
    end

    it 'reads trade-style price keys' do
      tick = gateway.send(:normalize_tick, 'B-ETH_USDT', { 'price' => '2254.1' })
      expect(tick.price).to eq(BigDecimal('2254.1'))
    end

    it 'uses first hash in an array payload' do
      tick = gateway.send(:normalize_tick, 'B-SOL_USDT', [{ 'p' => '84.5' }])
      expect(tick.price).to eq(BigDecimal('84.5'))
    end
  end
end
