# frozen_string_literal: true

require 'coindcx_bot/regime/transition_meaning'

RSpec.describe CoindcxBot::Regime::TransitionMeaning do
  it 'maps RANGE → TREND_UP to breakout narrative' do
    d = described_class.describe('RANGE', 'TREND_UP')
    expect(d[:meaning]).to include('breakout')
    expect(d[:bias]).to eq(:follow_long)
    expect(d[:action]).to include('pullback')
  end

  it 'falls back to generic narrative for unmapped pair' do
    d = described_class.describe('FOO', 'BAR')
    expect(d[:meaning]).to eq('FOO → BAR')
    expect(d[:bias]).to eq(:unknown)
    expect(d[:action]).to eq('Review manually')
  end

  it 'provides action for known target label even without transition match' do
    d = described_class.describe('UNMAPPED', 'CHOP')
    expect(d[:bias]).to eq(:stand_aside)
    expect(d[:action]).to include('Wait')
  end
end
