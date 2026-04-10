# frozen_string_literal: true

RSpec.describe CoindcxBot::SyntheticL1 do
  describe '.quote_from_mid' do
    it 'returns nil pair when mid is not positive' do
      expect(described_class.quote_from_mid(0)).to eq([nil, nil])
      expect(described_class.quote_from_mid(-1)).to eq([nil, nil])
    end

    it 'returns symmetric 1 bp spread around mid' do
      bid, ask = described_class.quote_from_mid(BigDecimal('100'))
      expect(bid).to eq(BigDecimal('99.99'))
      expect(ask).to eq(BigDecimal('100.01'))
    end
  end

  describe '.quote_from_mid_as_float' do
    it 'returns floats for TickStore' do
      b, a = described_class.quote_from_mid_as_float('50')
      expect(b).to be_within(1e-9).of(49.995)
      expect(a).to be_within(1e-9).of(50.005)
    end
  end
end
