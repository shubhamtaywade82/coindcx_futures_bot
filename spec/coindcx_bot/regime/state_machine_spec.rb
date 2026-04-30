# frozen_string_literal: true

require 'coindcx_bot/regime/state_machine'

RSpec.describe CoindcxBot::Regime::StateMachine do
  it 'returns nil until confirmations reached' do
    sm = described_class.new(confirmations: 2)
    expect(sm.update(state_id: 1, label: 'TREND_UP', posterior: 0.8)).to be_nil
    stable = sm.update(state_id: 1, label: 'TREND_UP', posterior: 0.82)
    expect(stable).to eq(state_id: 1, label: 'TREND_UP', posterior: 0.82)
  end

  it 'keeps previous stable while buffer unsettled' do
    sm = described_class.new(confirmations: 2)
    sm.update(state_id: 1, label: 'TREND_UP', posterior: 0.8)
    sm.update(state_id: 1, label: 'TREND_UP', posterior: 0.9)
    sm.update(state_id: 2, label: 'CHOP', posterior: 0.52)
    expect(sm.stable_state[:state_id]).to eq(1)
  end

  it 'promotes new state after confirmations reached' do
    sm = described_class.new(confirmations: 2)
    sm.update(state_id: 1, label: 'TREND_UP', posterior: 0.8)
    sm.update(state_id: 1, label: 'TREND_UP', posterior: 0.85)
    sm.update(state_id: 2, label: 'RANGE', posterior: 0.7)
    sm.update(state_id: 2, label: 'RANGE', posterior: 0.72)
    expect(sm.stable_state[:state_id]).to eq(2)
    expect(sm.stable_state[:label]).to eq('RANGE')
  end

  it 'clamps confirmations to minimum 1' do
    sm = described_class.new(confirmations: 0)
    expect(sm.update(state_id: 1, label: 'TREND_UP', posterior: 0.9)).not_to be_nil
  end

  it 'ignores nil state updates' do
    sm = described_class.new(confirmations: 2)
    sm.update(state_id: 1, label: 'TREND_UP', posterior: 0.8)
    sm.update(state_id: 1, label: 'TREND_UP', posterior: 0.85)
    sm.update(state_id: nil, label: nil, posterior: nil)
    expect(sm.stable_state[:state_id]).to eq(1)
  end
end
