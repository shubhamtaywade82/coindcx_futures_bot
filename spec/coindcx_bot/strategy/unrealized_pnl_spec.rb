# frozen_string_literal: true

require 'bigdecimal'

RSpec.describe CoindcxBot::Strategy::UnrealizedPnl do
  it 'returns long PnL as (ltp - entry) * qty' do
    pos = { side: 'long', entry_price: '100', quantity: '2' }
    expect(described_class.position_usdt(pos, BigDecimal('103'))).to eq(BigDecimal('6'))
  end

  it 'returns short PnL as (entry - ltp) * qty' do
    pos = { side: 'short', entry_price: '100', quantity: '1' }
    expect(described_class.position_usdt(pos, BigDecimal('97'))).to eq(BigDecimal('3'))
  end

  it 'returns nil when ltp is nil' do
    expect(described_class.position_usdt({ side: 'long', entry_price: '1', quantity: '1' }, nil)).to be_nil
  end
end
