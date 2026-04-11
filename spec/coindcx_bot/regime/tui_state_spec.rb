# frozen_string_literal: true

RSpec.describe CoindcxBot::Regime::TuiState do
  describe '.build' do
    it 'returns disabled payload when config omits regime_enabled?' do
      cfg = Object.new
      expect(described_class.build(cfg)).to eq(described_class.disabled)
    end

    it 'returns disabled payload when regime is off' do
      cfg = instance_double(CoindcxBot::Config, regime_enabled?: false, regime_ai_enabled?: false)
      expect(described_class.build(cfg)).to eq(described_class.disabled)
    end

    it 'returns standby payload when regime is enabled without AI' do
      cfg = instance_double(CoindcxBot::Config, regime_enabled?: true, regime_ai_enabled?: false)
      st = described_class.build(cfg)
      expect(st[:enabled]).to be(true)
      expect(st[:status]).to eq('PIPE:IDLE')
      expect(st[:label]).to eq('STANDBY')
      expect(st[:hmm_display]).to include('HmmEngine')
    end

    it 'returns standby-ai payload when regime AI is enabled' do
      cfg = instance_double(CoindcxBot::Config, regime_enabled?: true, regime_ai_enabled?: true)
      st = described_class.build(cfg)
      expect(st[:hmm_display]).to eq('AI: pending')
    end
  end
end
