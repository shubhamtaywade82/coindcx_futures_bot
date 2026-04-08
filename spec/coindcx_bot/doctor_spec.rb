# frozen_string_literal: true

RSpec.describe CoindcxBot::Doctor do
  describe '.normalize_instruments' do
    it 'wraps an array of pair strings' do
      raw = %w[B-SOL_USDT B-ETH_USDT B-BTC_USDT]
      rows = described_class.normalize_instruments(raw)
      expect(rows).to eq(
        [
          { pair: 'B-SOL_USDT' },
          { pair: 'B-ETH_USDT' },
          { pair: 'B-BTC_USDT' }
        ]
      )
    end

    it 'unwraps instruments key' do
      raw = { 'instruments' => %w[B-SOL_USDT] }
      rows = described_class.normalize_instruments(raw)
      expect(rows.first[:pair]).to eq('B-SOL_USDT')
    end

    it 'maps object-style hash pair => metadata' do
      raw = { 'B-SOL_USDT' => { 'foo' => 1 } }
      rows = described_class.normalize_instruments(raw)
      expect(rows.first[:pair]).to eq('B-SOL_USDT')
      expect(rows.first[:foo]).to eq(1)
    end
  end

  describe '.pair_from_row' do
    it 'reads standard keys' do
      expect(described_class.pair_from_row(pair: 'B-SOL_USDT')).to eq('B-SOL_USDT')
    end

    it 'finds B-* style string in values' do
      expect(described_class.pair_from_row(unknown: 'B-ETH_USDT')).to eq('B-ETH_USDT')
    end
  end

  describe '.match_sol_eth?' do
    it 'matches only native SOL and ETH USDT perps' do
      expect(described_class.match_sol_eth?({ pair: 'B-SOL_USDT' })).to be true
      expect(described_class.match_sol_eth?({ pair: 'B-ETH_USDT' })).to be true
      expect(described_class.match_sol_eth?({ pair: 'B-BTC_USDT' })).to be false
      expect(described_class.match_sol_eth?({ pair: 'B-SOLV_USDT' })).to be false
      expect(described_class.match_sol_eth?({ pair: 'B-ETHFI_USDT' })).to be false
    end
  end
end
