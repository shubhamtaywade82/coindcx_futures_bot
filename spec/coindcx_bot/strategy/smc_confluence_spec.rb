# frozen_string_literal: true

require 'bigdecimal'

RSpec.describe CoindcxBot::Strategy::SmcConfluence do
  def bar_result(long_signal:, short_signal: false)
    CoindcxBot::SmcConfluence::BarResult.new(
      bar_index: 0,
      bos_bull: false,
      bos_bear: false,
      choch_bull: long_signal,
      choch_bear: short_signal,
      structure_bias: 1,
      in_bull_ob: long_signal,
      in_bear_ob: short_signal,
      bull_ob_valid: true,
      bear_ob_valid: false,
      bull_ob_hi: nil,
      bull_ob_lo: nil,
      bear_ob_hi: nil,
      bear_ob_lo: nil,
      recent_bull_sweep: long_signal,
      recent_bear_sweep: short_signal,
      liq_sweep_bull: false,
      liq_sweep_bear: false,
      ms_trend: 1,
      tl_bear_break: false,
      tl_bull_break: false,
      tl_bear_retest: false,
      tl_bull_retest: false,
      sess_level_bull: long_signal,
      sess_level_bear: short_signal,
      vp_bull_conf: false,
      vp_bear_conf: false,
      near_poc: false,
      near_vah: false,
      near_val: false,
      long_score: long_signal ? 4 : 0,
      short_score: short_signal ? 4 : 0,
      long_signal: long_signal,
      short_signal: short_signal,
      pdh_sweep: false,
      pdl_sweep: false,
      pdh: nil,
      pdl: nil,
      poc: nil,
      vah: nil,
      val_line: nil,
      atr14: 1.0
    )
  end

  def dto_candles(n)
    Array.new(n) do |i|
      CoindcxBot::Dto::Candle.new(
        time: Time.utc(2024, 6, 1) + i * 3600,
        open: 100,
        high: 101,
        low: 99,
        close: 100.5,
        volume: 100
      )
    end
  end

  let(:strat_cfg) do
    {
      name: 'smc_confluence',
      stop_distance_pct_for_sizing: 0.02,
      take_profit_pct: 0,
      htf_alignment: false,
      smc_confluence: { min_score: 2, vp_bars: 8 }
    }
  end

  let(:strategy) { described_class.new(strat_cfg) }

  it 'holds when execution series is too short' do
    sig = strategy.evaluate(
      pair: 'B-SOL_USDT',
      candles_htf: [],
      candles_exec: [],
      position: nil,
      ltp: BigDecimal('100')
    )
    expect(sig.action).to eq(:hold)
    expect(sig.reason).to eq('insufficient_exec_bars')
  end

  it 'emits open_long when SMC-CE last bar is long_signal' do
    dtos = dto_candles(120)
    series = Array.new(119) { bar_result(long_signal: false) } + [bar_result(long_signal: true)]
    allow(CoindcxBot::SmcConfluence::Engine).to receive(:run).and_return(series)

    sig = strategy.evaluate(
      pair: 'B-SOL_USDT',
      candles_htf: dtos,
      candles_exec: dtos,
      position: nil,
      ltp: BigDecimal('100')
    )
    expect(sig.action).to eq(:open_long)
    expect(sig.side).to eq(:long)
    expect(sig.reason).to eq('smc_long_signal')
    expect(sig.stop_price).to eq(BigDecimal('100') * BigDecimal('0.98'))
    expect(sig.metadata[:long_score]).to eq(4)
  end

  it 'closes long when opposite short_signal fires on the last bar' do
    dtos = dto_candles(120)
    series = Array.new(119) { bar_result(long_signal: false) } + [bar_result(long_signal: false, short_signal: true)]
    allow(CoindcxBot::SmcConfluence::Engine).to receive(:run).and_return(series)

    pos = { id: 1, pair: 'B-SOL_USDT', side: 'long', entry_price: '99', quantity: '0.1', stop_price: '98' }
    sig = strategy.evaluate(
      pair: 'B-SOL_USDT',
      candles_htf: dtos,
      candles_exec: dtos,
      position: pos,
      ltp: BigDecimal('100')
    )
    expect(sig.action).to eq(:close)
    expect(sig.reason).to eq('smc_opposite_short')
  end

  it 'holds long on opposite short_signal when min gain is 0 and mark is not above entry' do
    cfg = strat_cfg.merge(smc_confluence: { min_score: 2, vp_bars: 8, opposite_smc_min_gain_pct: 0 })
    strat = described_class.new(cfg)
    dtos = dto_candles(120)
    series = Array.new(119) { bar_result(long_signal: false) } + [bar_result(long_signal: false, short_signal: true)]
    allow(CoindcxBot::SmcConfluence::Engine).to receive(:run).and_return(series)

    pos = { id: 1, pair: 'B-SOL_USDT', side: 'long', entry_price: '100', quantity: '0.1', stop_price: '98' }
    sig = strat.evaluate(
      pair: 'B-SOL_USDT',
      candles_htf: dtos,
      candles_exec: dtos,
      position: pos,
      ltp: BigDecimal('99.5')
    )
    expect(sig.action).to eq(:hold)
    expect(sig.reason).to eq('smc_opp_hold_gain')
  end

  it 'still closes long on opposite short_signal when min gain is 0 and mark is above entry' do
    cfg = strat_cfg.merge(smc_confluence: { min_score: 2, vp_bars: 8, opposite_smc_min_gain_pct: 0 })
    strat = described_class.new(cfg)
    dtos = dto_candles(120)
    series = Array.new(119) { bar_result(long_signal: false) } + [bar_result(long_signal: false, short_signal: true)]
    allow(CoindcxBot::SmcConfluence::Engine).to receive(:run).and_return(series)

    pos = { id: 1, pair: 'B-SOL_USDT', side: 'long', entry_price: '100', quantity: '0.1', stop_price: '98' }
    sig = strat.evaluate(
      pair: 'B-SOL_USDT',
      candles_htf: dtos,
      candles_exec: dtos,
      position: pos,
      ltp: BigDecimal('100.01')
    )
    expect(sig.action).to eq(:close)
    expect(sig.reason).to eq('smc_opposite_short')
  end

  it 'holds long on opposite short_signal when unrealized gain is below opposite_smc_min_gain_pct' do
    cfg = strat_cfg.merge(smc_confluence: { min_score: 2, vp_bars: 8, opposite_smc_min_gain_pct: 0.02 })
    strat = described_class.new(cfg)
    dtos = dto_candles(120)
    series = Array.new(119) { bar_result(long_signal: false) } + [bar_result(long_signal: false, short_signal: true)]
    allow(CoindcxBot::SmcConfluence::Engine).to receive(:run).and_return(series)

    pos = { id: 1, pair: 'B-SOL_USDT', side: 'long', entry_price: '100', quantity: '0.1', stop_price: '98' }
    sig = strat.evaluate(
      pair: 'B-SOL_USDT',
      candles_htf: dtos,
      candles_exec: dtos,
      position: pos,
      ltp: BigDecimal('101')
    )
    expect(sig.action).to eq(:hold)
    expect(sig.reason).to eq('smc_opp_hold_gain')
  end

  it 'holds short on opposite long_signal when min gain is 0 and mark is not below entry' do
    cfg = strat_cfg.merge(smc_confluence: { min_score: 2, vp_bars: 8, opposite_smc_min_gain_pct: 0 })
    strat = described_class.new(cfg)
    dtos = dto_candles(120)
    series = Array.new(119) { bar_result(long_signal: false) } + [bar_result(long_signal: true, short_signal: false)]
    allow(CoindcxBot::SmcConfluence::Engine).to receive(:run).and_return(series)

    pos = { id: 1, pair: 'B-SOL_USDT', side: 'short', entry_price: '100', quantity: '0.1', stop_price: '102' }
    sig = strat.evaluate(
      pair: 'B-SOL_USDT',
      candles_htf: dtos,
      candles_exec: dtos,
      position: pos,
      ltp: BigDecimal('100.5')
    )
    expect(sig.action).to eq(:hold)
    expect(sig.reason).to eq('smc_opp_hold_gain')
  end

  it 'holds when opposite signal fires but close_on_opposite_smc is false' do
    cfg = strat_cfg.merge(smc_confluence: { min_score: 2, vp_bars: 8, close_on_opposite_smc: false })
    strat = described_class.new(cfg)
    dtos = dto_candles(120)
    series = Array.new(119) { bar_result(long_signal: false) } + [bar_result(long_signal: false, short_signal: true)]
    allow(CoindcxBot::SmcConfluence::Engine).to receive(:run).and_return(series)

    pos = { id: 1, pair: 'B-SOL_USDT', side: 'long', entry_price: '99', quantity: '0.1', stop_price: '98' }
    sig = strat.evaluate(
      pair: 'B-SOL_USDT',
      candles_htf: dtos,
      candles_exec: dtos,
      position: pos,
      ltp: BigDecimal('110')
    )
    expect(sig.action).to eq(:hold)
    expect(sig.reason).to eq('smc_opp_flip_disabled')
  end

  it 'uses a descriptive hold reason when bullish primary is on but score is below min' do
    dtos = dto_candles(120)
    weak = CoindcxBot::SmcConfluence::BarResult.new(
      bar_index: 119,
      bos_bull: true,
      bos_bear: false,
      choch_bull: false,
      choch_bear: false,
      structure_bias: 1,
      in_bull_ob: false,
      in_bear_ob: false,
      bull_ob_valid: true,
      bear_ob_valid: false,
      bull_ob_hi: nil,
      bull_ob_lo: nil,
      bear_ob_hi: nil,
      bear_ob_lo: nil,
      recent_bull_sweep: false,
      recent_bear_sweep: false,
      liq_sweep_bull: false,
      liq_sweep_bear: false,
      ms_trend: 0,
      tl_bear_break: false,
      tl_bull_break: false,
      tl_bear_retest: false,
      tl_bull_retest: false,
      sess_level_bull: false,
      sess_level_bear: false,
      vp_bull_conf: false,
      vp_bear_conf: false,
      near_poc: false,
      near_vah: false,
      near_val: false,
      long_score: 1,
      short_score: 0,
      long_signal: false,
      short_signal: false,
      pdh_sweep: false,
      pdl_sweep: false,
      pdh: nil,
      pdl: nil,
      poc: nil,
      vah: nil,
      val_line: nil,
      atr14: 1.0
    )
    series = Array.new(119) { bar_result(long_signal: false) } + [weak]
    allow(CoindcxBot::SmcConfluence::Engine).to receive(:run).and_return(series)

    strat = described_class.new(strat_cfg.merge(smc_confluence: { min_score: 2, signal_mode: 'bos_relaxed' }))
    sig = strat.evaluate(
      pair: 'B-SOL_USDT',
      candles_htf: dtos,
      candles_exec: dtos,
      position: nil,
      ltp: BigDecimal('100')
    )
    expect(sig.action).to eq(:hold)
    expect(sig.reason).to eq('smc_l_weak L1/2')
  end

  it 'takes profit when take_profit_pct is set and gain exceeds threshold' do
    cfg = strat_cfg.merge(take_profit_pct: 0.01)
    strat = described_class.new(cfg)
    dtos = dto_candles(120)
    series = Array.new(119) { bar_result(long_signal: false) } + [bar_result(long_signal: false)]
    allow(CoindcxBot::SmcConfluence::Engine).to receive(:run).and_return(series)

    pos = { id: 1, pair: 'B-SOL_USDT', side: 'long', entry_price: '99', quantity: '0.1', stop_price: '98' }
    sig = strat.evaluate(
      pair: 'B-SOL_USDT',
      candles_htf: dtos,
      candles_exec: dtos,
      position: pos,
      ltp: BigDecimal('100.5')
    )
    expect(sig.action).to eq(:close)
    expect(sig.reason).to eq('smc_take_profit_pct')
  end
end
