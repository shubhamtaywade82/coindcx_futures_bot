# frozen_string_literal: true

require 'bigdecimal'

RSpec.describe CoindcxBot::Strategy::HwmPriceTrail do
  let(:base_cfg) { { hwm_price_trail: { enabled: true, activate_gain_pct: 0.15, pullback_from_peak_pct: 0.05 } } }

  describe '.check' do
    it 'returns nil until peak favorable return reaches activate_gain_pct' do
      position = { id: 1, side: 'long', entry_price: '100', peak_ltp: '108' } # +8% peak
      expect(described_class.check(pair: 'B-X_USDT', position: position, ltp: BigDecimal('104'), strategy_cfg: base_cfg)).to be_nil
    end

    it 'closes long when armed and ltp pulls back past pullback_from_peak_pct from peak' do
      position = { id: 2, side: 'long', entry_price: '100', peak_ltp: '118' } # +18% peak
      sig = described_class.check(pair: 'B-X_USDT', position: position, ltp: BigDecimal('111'), strategy_cfg: base_cfg)
      expect(sig.action).to eq(:close)
      expect(sig.reason).to eq('hwm_price_trail')
      expect(sig.metadata[:position_id]).to eq(2)
    end

    it 'does not close long when pullback is shallow' do
      position = { id: 3, side: 'long', entry_price: '100', peak_ltp: '118' }
      sig = described_class.check(pair: 'B-X_USDT', position: position, ltp: BigDecimal('113'), strategy_cfg: base_cfg)
      expect(sig).to be_nil
    end

    it 'closes short when armed and price bounces up from trough by pullback pct' do
      cfg = { hwm_price_trail: { enabled: true, activate_gain_pct: 0.15, pullback_from_peak_pct: 0.05 } }
      position = { id: 4, side: 'short', entry_price: '100', peak_ltp: '82' } # trough 18% favorable
      sig = described_class.check(pair: 'B-X_USDT', position: position, ltp: BigDecimal('87.5'), strategy_cfg: cfg)
      expect(sig.action).to eq(:close)
      expect(sig.side).to eq(:short)
    end

    it 'returns nil when disabled' do
      position = { id: 5, side: 'long', entry_price: '100', peak_ltp: '200' }
      cfg = { hwm_price_trail: { enabled: false } }
      expect(described_class.check(pair: 'B-X_USDT', position: position, ltp: BigDecimal('1'), strategy_cfg: cfg)).to be_nil
    end
  end
end
