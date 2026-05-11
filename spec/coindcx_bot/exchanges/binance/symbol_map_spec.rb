# frozen_string_literal: true

RSpec.describe CoindcxBot::Exchanges::Binance::SymbolMap do
  described_class::BINANCE_TO_COINDCX.each do |binance_sym, coindcx_pair|
    it "round-trips #{binance_sym} ↔ #{coindcx_pair}" do
      expect(described_class.to_coindcx(binance_sym)).to eq(coindcx_pair)
      expect(described_class.to_binance(coindcx_pair)).to eq(binance_sym)
    end
  end
end
