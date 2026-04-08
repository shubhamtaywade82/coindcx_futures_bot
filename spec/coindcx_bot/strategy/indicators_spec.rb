# frozen_string_literal: true

RSpec.describe CoindcxBot::Strategy::Indicators do
  def c(t, o, h, l, cl, v = 1)
    CoindcxBot::Dto::Candle.new(
      time: Time.at(t), open: BigDecimal(o.to_s), high: BigDecimal(h.to_s),
      low: BigDecimal(l.to_s), close: BigDecimal(cl.to_s), volume: BigDecimal(v.to_s)
    )
  end

  describe '.volume_ratio_last' do
    it 'returns nil when not enough bars' do
      candles = [c(0, 1, 2, 0, 1, 10)]
      expect(described_class.volume_ratio_last(candles, lookback: 5)).to be_nil
    end

    it 'compares last volume to prior average' do
      base = 10.times.map { |i| c(i, 1, 2, 0, 1, 100) }
      candles = base + [c(10, 1, 2, 0, 1, 200)]
      expect(described_class.volume_ratio_last(candles, lookback: 5)).to eq(BigDecimal('2'))
    end
  end

  describe '.directional_structure?' do
    it 'is true for monotonic HH/HL long structure' do
      candles = [c(0, 1, 2, 1, 1.5), c(1, 1, 3, 2, 2.5), c(2, 2, 4, 3, 3.5)]
      expect(described_class.directional_structure?(candles, :long, bars: 3)).to be true
    end

    it 'is false when highs do not rise' do
      candles = [c(0, 1, 3, 1, 2), c(1, 1, 2, 1, 1.5)]
      expect(described_class.directional_structure?(candles, :long, bars: 2)).to be false
    end
  end

  describe '.adx_last' do
    it 'returns a positive number on a long directional series' do
      candles = 60.times.map do |i|
        base = BigDecimal(i)
        c(i, base, base + 2, base - 0.5, base + 1.5, 1000)
      end
      adx = described_class.adx_last(candles, period: 14)
      expect(adx).to be_a(BigDecimal)
      expect(adx).to be > 0
    end
  end
end
