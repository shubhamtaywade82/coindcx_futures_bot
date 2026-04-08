# frozen_string_literal: true

RSpec.describe CoindcxBot::Gateways::WsGateway do
  describe '#normalize_tick (private)' do
    let(:client) { instance_double(CoinDCX::Client, ws: nil) }
    let(:gateway) { described_class.new(client: client) }

    it 'uses instrument when symbol field is absent' do
      tick = gateway.send(:normalize_tick, 'B-SOL_USDT', { 'p' => '123.45' })
      expect(tick.pair).to eq('B-SOL_USDT')
    end

    it 'uses payload symbol when present' do
      tick = gateway.send(:normalize_tick, 'B-SOL_USDT', { 'p' => '1', 's' => 'B-ETH_USDT' })
      expect(tick.pair).to eq('B-ETH_USDT')
    end
  end
end
