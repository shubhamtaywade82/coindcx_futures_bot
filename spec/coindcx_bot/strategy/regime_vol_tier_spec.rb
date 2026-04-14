# frozen_string_literal: true

require 'spec_helper'
require_relative '../../../lib/coindcx_bot/strategy/regime_vol_tier'
require_relative '../../../lib/coindcx_bot/strategy/signal'

RSpec.describe CoindcxBot::Strategy::RegimeVolTier do
  let(:inner) do
    Class.new do
      def evaluate(pair:, candles_htf:, candles_exec:, position:, ltp:, regime_hint: nil)
        CoindcxBot::Strategy::Signal.new(
          action: :open_long,
          pair: pair,
          side: 'buy',
          stop_price: BigDecimal('90'),
          reason: 'test',
          metadata: {}
        )
      end
    end.new
  end

  it 'blocks new entries in high vol when block_entries_high_vol is true' do
    strat = described_class.new(
      { block_entries_high_vol: true },
      inner: inner
    )
    hint = { tier: :high_vol, state: Struct.new(:uncertainty, :flickering).new(false, false) }
    sig = strat.evaluate(
      pair: 'B-X_USDT',
      candles_htf: [],
      candles_exec: [],
      position: nil,
      ltp: BigDecimal('100'),
      regime_hint: hint
    )
    expect(sig.action).to eq(:hold)
    expect(sig.reason).to eq('regime_high_vol')
  end

  it 'allows manage when position open' do
    inner_manage = Class.new do
      def evaluate(pair:, candles_htf:, candles_exec:, position:, ltp:, regime_hint: nil)
        CoindcxBot::Strategy::Signal.new(action: :hold, pair: pair, side: nil, stop_price: nil, reason: 'trail', metadata: {})
      end
    end.new
    strat = described_class.new({ block_entries_high_vol: true }, inner: inner_manage)
    pos = { pair: 'B-X_USDT' }
    sig = strat.evaluate(
      pair: 'B-X_USDT',
      candles_htf: [],
      candles_exec: [],
      position: pos,
      ltp: BigDecimal('100'),
      regime_hint: { tier: :high_vol }
    )
    expect(sig.reason).to eq('trail')
  end
end
