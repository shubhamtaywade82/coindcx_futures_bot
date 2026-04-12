# frozen_string_literal: true

RSpec.describe CoindcxBot::SmcConfluence::Candles do
  describe '.from_dto' do
    it 'maps Dto::Candle to engine hashes with integer timestamp' do
      t = Time.utc(2024, 1, 2, 3, 4, 5)
      c = CoindcxBot::Dto::Candle.new(time: t, open: 1, high: 2, low: 0.5, close: 1.5, volume: 99)
      rows = described_class.from_dto([c])
      expect(rows.size).to eq(1)
      expect(rows[0]).to eq(
        timestamp: t.to_i,
        open: 1,
        high: 2,
        low: 0.5,
        close: 1.5,
        volume: 99
      )
    end
  end
end
