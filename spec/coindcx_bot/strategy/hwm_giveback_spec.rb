# frozen_string_literal: true

require 'bigdecimal'

RSpec.describe CoindcxBot::Strategy::HwmGiveback do
  let(:base_pos) do
    {
      id: 42,
      side: 'long',
      entry_price: '100',
      quantity: '1',
      stop_price: '90',
      partial_done: 0,
      peak_unrealized_usdt: '15'
    }
  end

  let(:cfg) do
    {
      hwm_giveback: {
        enabled: true,
        min_peak_usdt: 10,
        giveback_pct: 0.35
      }
    }
  end

  it 'returns nil when disabled' do
    c = { hwm_giveback: { enabled: false } }
    sig = described_class.check(pair: 'B-SOL_USDT', position: base_pos, ltp: BigDecimal('100'), strategy_cfg: c)
    expect(sig).to be_nil
  end

  it 'returns nil when peak is below min_peak_usdt' do
    pos = base_pos.merge(peak_unrealized_usdt: '5')
    sig = described_class.check(pair: 'B-SOL_USDT', position: pos, ltp: BigDecimal('104'), strategy_cfg: cfg)
    expect(sig).to be_nil
  end

  it 'closes when drawdown from peak exceeds giveback_pct' do
    # u = (108 - 100) * 1 = 8; peak 15; (15-8)/15 = 0.467 >= 0.35
    sig = described_class.check(pair: 'B-SOL_USDT', position: base_pos, ltp: BigDecimal('108'), strategy_cfg: cfg)
    expect(sig.action).to eq(:close)
    expect(sig.reason).to eq('hwm_giveback')
    expect(sig.metadata[:peak_usdt]).to eq('15.0')
    expect(sig.metadata[:current_usdt]).to eq('8.0')
  end

  it 'triggers on deep loss from peak when peak was positive' do
    pos = base_pos.merge(peak_unrealized_usdt: '15')
    sig = described_class.check(pair: 'B-SOL_USDT', position: pos, ltp: BigDecimal('95'), strategy_cfg: cfg)
    expect(sig).not_to be_nil
    expect(sig.action).to eq(:close)
  end

  it 'fires giveback_usdt when set even if pct is not met' do
    c = {
      hwm_giveback: {
        enabled: true,
        min_peak_usdt: 10,
        giveback_pct: 0.90,
        giveback_usdt: 4
      }
    }
    # peak 15, ltp 104 -> u = 4, drawdown 11, pct 11/15 < 0.9 but abs >= 4
    sig = described_class.check(pair: 'B-SOL_USDT', position: base_pos, ltp: BigDecimal('104'), strategy_cfg: c)
    expect(sig&.action).to eq(:close)
  end

  it 'returns nil when giveback_usdt alone would not fire and pct not met' do
    c = {
      hwm_giveback: {
        enabled: true,
        min_peak_usdt: 10,
        giveback_pct: 0.90,
        giveback_usdt: 20
      }
    }
    sig = described_class.check(pair: 'B-SOL_USDT', position: base_pos, ltp: BigDecimal('104'), strategy_cfg: c)
    expect(sig).to be_nil
  end
end
