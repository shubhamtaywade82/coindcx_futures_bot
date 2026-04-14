# frozen_string_literal: true

RSpec.describe CoindcxBot::SmcConfluence::Fvg do
  describe CoindcxBot::SmcConfluence::Fvg::Detector do
    def bar(high:, low:, open: nil, close: nil)
      o = open || low + (high - low) / 2.0
      c = close || o
      { high: high, low: low, open: o, close: c }
    end

    describe '.at_index' do
      it 'returns nil when fewer than three candles exist' do
        candles = [bar(high: 10, low: 9), bar(high: 10, low: 9)]
        expect(described_class.at_index(candles, 1)).to be_nil
      end

      it 'detects a bullish gap when candle1 high is below candle3 low' do
        candles = [
          bar(high: 100.0, low: 99.0),
          bar(high: 101.0, low: 99.5),
          bar(high: 112.0, low: 110.0, open: 110.5, close: 111.0)
        ]
        fvg = described_class.at_index(candles, 2)
        expect(fvg).to be_a(CoindcxBot::SmcConfluence::Fvg)
        expect(fvg.side).to eq(:bullish)
        expect(fvg.bar_index).to eq(2)
        expect(fvg.gap_low).to eq(100.0)
        expect(fvg.gap_high).to eq(110.0)
      end

      it 'detects a bearish gap when candle1 low is above candle3 high' do
        candles = [
          bar(high: 110.0, low: 105.0),
          bar(high: 104.0, low: 102.0),
          bar(high: 98.0, low: 95.0, open: 97.0, close: 96.0)
        ]
        fvg = described_class.at_index(candles, 2)
        expect(fvg.side).to eq(:bearish)
        expect(fvg.gap_low).to eq(98.0)
        expect(fvg.gap_high).to eq(105.0)
      end
    end
  end

  describe '#invalidated_by_ohlc?' do
    it 'invalidates a bullish FVG when low trades through the gap floor' do
      fvg = described_class.new(side: :bullish, bar_index: 2, gap_low: 100.0, gap_high: 110.0)
      expect(fvg.invalidated_by_ohlc?(105.0, 100.0)).to be(true)
      expect(fvg.invalidated_by_ohlc?(108.0, 100.5)).to be(false)
    end

    it 'invalidates a bearish FVG when high trades through the gap ceiling' do
      fvg = described_class.new(side: :bearish, bar_index: 2, gap_low: 95.0, gap_high: 105.0)
      expect(fvg.invalidated_by_ohlc?(106.0, 100.0)).to be(true)
      expect(fvg.invalidated_by_ohlc?(104.0, 99.0)).to be(false)
    end
  end

  describe '#overlaps_bar?' do
    it 'is true when the bar range intersects the gap' do
      fvg = described_class.new(side: :bullish, bar_index: 2, gap_low: 100.0, gap_high: 110.0)
      expect(fvg.overlaps_bar?(108.0, 105.0)).to be(true)
      expect(fvg.overlaps_bar?(99.0, 98.0)).to be(false)
    end
  end
end
