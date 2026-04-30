# frozen_string_literal: true

RSpec.describe CoindcxBot::SmcSetup::StateBuilder do
  let(:bar) do
    CoindcxBot::SmcConfluence::BarResult.new(
      bar_index: 5,
      bos_bull: true,
      bos_bear: false,
      choch_bull: false,
      choch_bear: false,
      structure_bias: 1,
      in_bull_ob: true,
      in_bear_ob: false,
      bull_ob_valid: true,
      bear_ob_valid: false,
      bull_ob_hi: 102.0,
      bull_ob_lo: 100.0,
      bear_ob_hi: nil,
      bear_ob_lo: nil,
      recent_bull_sweep: true,
      recent_bear_sweep: false,
      liq_sweep_bull: true,
      liq_sweep_bear: false,
      ms_trend: 1,
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
      long_score: 3,
      short_score: 0,
      long_signal: false,
      short_signal: false,
      pdh_sweep: false,
      pdl_sweep: false,
      pdh: nil,
      pdl: nil,
      poc: 101.0,
      vah: 103.0,
      val_line: 99.0,
      atr14: 1.25,
      fvg_bull_align: true,
      fvg_bear_align: false,
      in_discount: true,
      in_premium: false
    )
  end

  let(:candles) do
    [
      { timestamp: 1_700_000_000, open: 100, high: 101, low: 99.5, close: 100.5, volume: 1000 },
      { timestamp: 1_700_000_900, open: 100.5, high: 102, low: 100, close: 101.2, volume: 1100 }
    ]
  end

  it 'maps a bullish order block to a sorted zone from bull_ob_hi and bull_ob_lo' do
    snapshot = described_class.build(pair: 'B-SOL_USDT', bar_result: bar, candles: candles, timeframe: '15m')

    bullish = snapshot[:smc][:order_blocks].find { |z| z[:type] == 'bullish' }
    expect(bullish[:zone]).to eq([100.0, 102.0])
  end

  it 'marks orderflow as unavailable from REST-only context' do
    snapshot = described_class.build(pair: 'B-SOL_USDT', bar_result: bar, candles: candles, timeframe: '15m')

    expect(snapshot[:orderflow][:exchange_delta_available]).to be(false)
  end

  it 'labels premium_discount from bar flags' do
    snapshot = described_class.build(pair: 'B-SOL_USDT', bar_result: bar, candles: candles, timeframe: '15m')

    expect(snapshot[:smc][:premium_discount][:label]).to eq('discount')
  end
end
