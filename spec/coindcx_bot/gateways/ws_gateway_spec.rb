# frozen_string_literal: true

RSpec.describe CoindcxBot::Gateways::WsGateway do
  describe '#normalize_tick (private)' do
    let(:client) { instance_double(CoinDCX::Client, ws: nil) }
    let(:gateway) { described_class.new(client: client) }

    it 'uses instrument when symbol field is absent' do
      tick = gateway.send(:normalize_tick, 'B-SOL_USDT', { 'p' => '123.45' })
      expect(tick.pair).to eq('B-SOL_USDT')
    end

    it 'drops payload when symbol hint targets a different instrument (shared Socket.IO fan-out)' do
      expect(gateway.send(:normalize_tick, 'B-SOL_USDT', { 'p' => '1', 's' => 'B-ETH_USDT' })).to be_nil
    end

    it 'accepts payload when symbol hint matches the subscribed instrument' do
      tick = gateway.send(:normalize_tick, 'B-SOL_USDT', { 'p' => '99', 's' => 'SOLUSDT' })
      expect(tick.pair).to eq('B-SOL_USDT')
      expect(tick.price).to eq(BigDecimal('99'))
    end

    it 'unwraps nested data hashes from the wire' do
      tick = gateway.send(:normalize_tick, 'B-ETH_USDT', { 'data' => { 'p' => '2100.5' } })
      expect(tick.price).to eq(BigDecimal('2100.5'))
    end

    it 'parses JSON string payloads' do
      tick = gateway.send(:normalize_tick, 'B-SOL_USDT', '{"p":"10.5"}')
      expect(tick.price).to eq(BigDecimal('10.5'))
    end

    it 'unwraps CoinDCX envelope with JSON string in data (production wire shape)' do
      payload = {
        'event' => 'new-trade',
        'data' => '{"p":"71585.5","q":"0.01","s":"B-BTC_USDT","pr":"f"}'
      }
      tick = gateway.send(:normalize_tick, 'B-BTC_USDT', payload)
      expect(tick.price).to eq(BigDecimal('71585.5'))
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
