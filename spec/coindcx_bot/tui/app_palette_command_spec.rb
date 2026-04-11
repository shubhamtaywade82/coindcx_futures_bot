# frozen_string_literal: true

RSpec.describe CoindcxBot::Tui::App do
  describe '.normalize_palette_command' do
    it 'strips one or more leading slashes' do
      expect(described_class.normalize_palette_command('/focus 1')).to eq('focus 1')
      expect(described_class.normalize_palette_command('//pause')).to eq('pause')
    end

    it 'passes through plain commands' do
      expect(described_class.normalize_palette_command('help')).to eq('help')
    end
  end
end
