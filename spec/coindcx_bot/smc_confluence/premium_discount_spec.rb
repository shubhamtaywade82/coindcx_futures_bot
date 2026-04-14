# frozen_string_literal: true

RSpec.describe CoindcxBot::SmcConfluence::PremiumDiscount do
  describe '#equilibrium' do
    it 'returns the midpoint of the range' do
      pd = described_class.new(range_high: 120.0, range_low: 100.0)
      expect(pd.equilibrium).to eq(110.0)
    end
  end

  describe '#discount? and #premium?' do
    it 'treats close below equilibrium as discount' do
      pd = described_class.new(range_high: 120.0, range_low: 100.0)
      expect(pd.discount?(109.0)).to be(true)
      expect(pd.premium?(109.0)).to be(false)
    end

    it 'treats close above equilibrium as premium' do
      pd = described_class.new(range_high: 120.0, range_low: 100.0)
      expect(pd.premium?(111.0)).to be(true)
      expect(pd.discount?(111.0)).to be(false)
    end

    it 'returns false for both when the range is degenerate' do
      pd = described_class.new(range_high: 100.0, range_low: 100.0)
      expect(pd.discount?(99.0)).to be(false)
      expect(pd.premium?(101.0)).to be(false)
    end
  end
end
