# frozen_string_literal: true

RSpec.describe CoindcxBot::Regime::TuiState do
  describe '.build' do
    it 'returns disabled payload when config omits regime_enabled?' do
      cfg = Object.new
      expect(described_class.build(cfg)).to eq(described_class.disabled)
    end

    it 'returns disabled payload when regime is off' do
      cfg = instance_double(CoindcxBot::Config, regime_enabled?: false)
      expect(described_class.build(cfg)).to eq(described_class.disabled)
    end

    it 'returns standby payload when regime is enabled' do
      cfg = instance_double(CoindcxBot::Config, regime_enabled?: true)
      st = described_class.build(cfg)
      expect(st[:enabled]).to be(true)
      expect(st[:status]).to eq('PIPE:IDLE')
      expect(st[:label]).to eq('STANDBY')
      expect(st[:hmm_display]).to include('HmmEngine')
    end
  end
end
