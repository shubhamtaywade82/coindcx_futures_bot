# frozen_string_literal: true

require 'spec_helper'
require 'securerandom'
require_relative '../../../lib/coindcx_bot/strategy/meta_first_win'
require_relative '../../../lib/coindcx_bot/strategy/signal'

RSpec.describe CoindcxBot::Strategy::MetaFirstWin do
  let(:journal_path) { File.join(Dir.tmpdir, "coindcx_meta_first_#{SecureRandom.hex(8)}.sqlite3") }
  let(:journal) { CoindcxBot::Persistence::Journal.new(journal_path) }

  after do
    File.delete(journal_path) if File.exist?(journal_path)
  end

  let(:hold) do
    CoindcxBot::Strategy::Signal.new(
      action: :hold,
      pair: 'B-SOL_USDT',
      side: nil,
      stop_price: nil,
      reason: 'hold',
      metadata: {}
    )
  end

  let(:open_long) do
    CoindcxBot::Strategy::Signal.new(
      action: :open_long,
      pair: 'B-SOL_USDT',
      side: :long,
      stop_price: BigDecimal('90'),
      reason: 'child_open',
      metadata: { child_meta: 1 }
    )
  end

  let(:close_sig) do
    CoindcxBot::Strategy::Signal.new(
      action: :close,
      pair: 'B-SOL_USDT',
      side: :long,
      stop_price: nil,
      reason: 'child_close',
      metadata: {}
    )
  end

  let(:base_cfg) do
    {
      name: 'meta_first_win',
      execution_resolution: '15m',
      higher_timeframe_resolution: '1h',
      meta_first_win: {
        cooldown_seconds_after_close: 86_400,
        children: [
          { name: 'trend_continuation' },
          { name: 'supertrend_profit' }
        ]
      }
    }
  end

  let(:meta) { described_class.new(base_cfg, journal: journal) }

  def stub_children!(first_sig, second_sig)
    a = instance_double(CoindcxBot::Strategy::TrendContinuation)
    b = instance_double(CoindcxBot::Strategy::SupertrendProfit)
    allow(a).to receive(:evaluate).and_return(first_sig)
    allow(b).to receive(:evaluate).and_return(second_sig)
    meta.instance_variable_set(
      :@children,
      [
        { lane: 'trend_continuation', strat: a, priority: 0 },
        { lane: 'supertrend_profit', strat: b, priority: 1 }
      ]
    )
    [a, b]
  end

  it 'returns the first child open signal augmented with meta_lane and meta_priority' do
    stub_children!(open_long, hold)
    sig = meta.evaluate(
      pair: 'B-SOL_USDT',
      candles_htf: [],
      candles_exec: [],
      position: nil,
      ltp: BigDecimal('100'),
      regime_hint: nil
    )
    expect(sig.action).to eq(:open_long)
    expect(sig.metadata[:meta_lane]).to eq('trend_continuation')
    expect(sig.metadata[:meta_priority]).to eq(0)
    expect(sig.reason).to eq('meta_first_win(child_open)')
  end

  it 'scans the second child when the first only holds' do
    stub_children!(hold, open_long)
    sig = meta.evaluate(
      pair: 'B-SOL_USDT',
      candles_htf: [],
      candles_exec: [],
      position: nil,
      ltp: BigDecimal('100'),
      regime_hint: nil
    )
    expect(sig.action).to eq(:open_long)
    expect(sig.metadata[:meta_lane]).to eq('supertrend_profit')
    expect(sig.metadata[:meta_priority]).to eq(1)
  end

  it 'delegates manage/exit to the child matching entry_lane on the position row' do
    _a, b = stub_children!(hold, close_sig)
    pos = { pair: 'B-SOL_USDT', entry_lane: 'supertrend_profit' }
    sig = meta.evaluate(
      pair: 'B-SOL_USDT',
      candles_htf: [],
      candles_exec: [],
      position: pos,
      ltp: BigDecimal('100'),
      regime_hint: nil
    )
    expect(sig.action).to eq(:close)
    expect(b).to have_received(:evaluate).once
  end

  it 'falls back to the first child when entry_lane is blank (legacy journal rows)' do
    a, _b = stub_children!(close_sig, hold)
    pos = { pair: 'B-SOL_USDT', entry_lane: nil }
    meta.evaluate(
      pair: 'B-SOL_USDT',
      candles_htf: [],
      candles_exec: [],
      position: pos,
      ltp: BigDecimal('100'),
      regime_hint: nil
    )
    expect(a).to have_received(:evaluate).once
  end

  it 'returns meta_cooldown when journal meta is still inside the cooldown window' do
    stub_children!(open_long, hold)
    journal.meta_set(
      "#{described_class::COOLDOWN_META_PREFIX}B-SOL_USDT",
      (Time.now.to_f + 60).to_s
    )
    sig = meta.evaluate(
      pair: 'B-SOL_USDT',
      candles_htf: [],
      candles_exec: [],
      position: nil,
      ltp: BigDecimal('100'),
      regime_hint: nil
    )
    expect(sig.action).to eq(:hold)
    expect(sig.reason).to eq('meta_cooldown')
  end

  it 'records cooldown via class helper using Config' do
    cfg = CoindcxBot::Config.new(
      minimal_bot_config(
        strategy: {
          name: 'meta_first_win',
          execution_resolution: '15m',
          higher_timeframe_resolution: '1h',
          meta_first_win: {
            cooldown_seconds_after_close: 12,
            children: [{ name: 'trend_continuation' }, { name: 'supertrend_profit' }]
          }
        }
      )
    )
    described_class.record_entry_cooldown(journal: journal, config: cfg, pair: 'B-SOL_USDT')
    raw = journal.meta_get("#{described_class::COOLDOWN_META_PREFIX}B-SOL_USDT")
    expect(Float(raw)).to be > Time.now.to_f
  end
end
