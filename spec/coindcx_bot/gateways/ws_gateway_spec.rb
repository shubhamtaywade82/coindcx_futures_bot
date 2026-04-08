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

    it 'extracts change_pct from pc field' do
      tick = gateway.send(:normalize_tick, 'B-SOL_USDT', { 'p' => '142.50', 'pc' => '-1.23' })

      expect(tick.change_pct).to eq(BigDecimal('-1.23'))
    end

    it 'returns nil change_pct when pc is absent' do
      tick = gateway.send(:normalize_tick, 'B-SOL_USDT', { 'p' => '142.50' })

      expect(tick.change_pct).to be_nil
    end

    it 'extracts change_pct from change_pct field' do
      tick = gateway.send(:normalize_tick, 'B-SOL_USDT', { 'p' => '142.50', 'change_pct' => '2.5' })

      expect(tick.change_pct).to eq(BigDecimal('2.5'))
    end
  end
end
