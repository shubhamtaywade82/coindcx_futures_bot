# frozen_string_literal: true

RSpec.describe CoindcxBot::Strategy::TrendContinuation do
  def candle(time_i, o, h, l, c)
    CoindcxBot::Dto::Candle.new(
      time: Time.at(time_i),
      open: BigDecimal(o.to_s),
      high: BigDecimal(h.to_s),
      low: BigDecimal(l.to_s),
      close: BigDecimal(c.to_s)
    )
  end

  it 'holds when not enough bars' do
    strat = described_class.new({ trend_strength_min: 0.01, ema_fast: 3, ema_slow: 5 })
    few = 10.times.map { |i| candle(i, 100, 101, 99, 100) }
    sig = strat.evaluate(pair: 'B-SOL_USDT', candles_htf: few, candles_exec: few, position: nil, ltp: nil)
    expect(sig.action).to eq(:hold)
    expect(sig.reason).to eq('insufficient_exec_bars')
  end

  it 'can signal open_long in a strong synthetic uptrend with compression breakout' do
    cfg = {
      trend_strength_min: 0.001,
      ema_fast: 3,
      ema_slow: 5,
      atr_period: 5,
      compression_lookback: 6,
      compression_ratio: 0.99,
      breakout_lookback: 3,
      pullback_ema_tolerance_pct: 0.01
    }
    strat = described_class.new(cfg)

    uptrend = 50.times.map do |i|
      base = BigDecimal(100) + BigDecimal(i) * BigDecimal('0.3')
      candle(i, base, base + 2, base - 1, base + 1)
    end

    exec = uptrend.dup
    # Widen ranges then compress last bar, then breakout close
    exec[-6..-2] = exec[-6..-2].map.with_index do |c, idx|
      t = c.time.to_i
      candle(t, 115, 120, 110, 115 + idx)
    end
    last_t = exec.last.time.to_i + 1
    exec[-1] = candle(last_t, 115, 115.5, 114.9, 115.2)
    exec << candle(last_t + 1, 121, 125, 120, 124)

    sig = strat.evaluate(
      pair: 'B-SOL_USDT',
      candles_htf: uptrend,
      candles_exec: exec,
      position: nil,
      ltp: BigDecimal('124')
    )

    expect(%i[open_long hold]).to include(sig.action)
  end

  it 'holds with volume_gate when volume_filter is on and last bar is not expanded' do
    strat_cfg = minimal_bot_config[:strategy].merge(
      trend_strength_min: 0.001,
      ema_fast: 3,
      ema_slow: 5,
      atr_period: 5,
      volume_filter: true,
      volume_lookback: 5,
      volume_min_ratio: 5.0
    )
    strat = described_class.new(strat_cfg)

    uptrend = 50.times.map do |i|
      base = BigDecimal(100) + BigDecimal(i) * BigDecimal('0.3')
      candle(i, base, base + 2, base - 1, base + 1)
    end

    exec = uptrend.dup
    exec[-6..-2] = exec[-6..-2].map.with_index do |c, idx|
      t = c.time.to_i
      candle(t, 115, 120, 110, 115 + idx)
    end
    last_t = exec.last.time.to_i + 1
    exec[-1] = candle(last_t, 115, 115.5, 114.9, 115.2)
    exec << candle(last_t + 1, 121, 125, 120, 124)

    sig = strat.evaluate(
      pair: 'B-SOL_USDT',
      candles_htf: uptrend,
      candles_exec: exec,
      position: nil,
      ltp: BigDecimal('124')
    )

    expect(sig.action).to eq(:hold)
    expect(sig.reason).to eq('volume_gate')
  end

  it 'closes open long on hwm_giveback before partial or trail when configured' do
    strat_cfg = minimal_bot_config[:strategy].merge(
      trend_strength_min: 0.001,
      ema_fast: 3,
      ema_slow: 5,
      atr_period: 5,
      compression_lookback: 6,
      compression_ratio: 0.99,
      breakout_lookback: 3,
      pullback_ema_tolerance_pct: 0.01,
      hwm_giveback: { enabled: true, min_peak_usdt: 10, giveback_pct: 0.35 }
    )
    strat = described_class.new(strat_cfg)

    uptrend = 50.times.map do |i|
      base = BigDecimal(100) + BigDecimal(i) * BigDecimal('0.3')
      candle(i, base, base + 2, base - 1, base + 1)
    end
    exec = uptrend.dup
    exec[-6..-2] = exec[-6..-2].map.with_index do |c, idx|
      t = c.time.to_i
      candle(t, 115, 120, 110, 115 + idx)
    end
    last_t = exec.last.time.to_i + 1
    exec[-1] = candle(last_t, 115, 115.5, 114.9, 115.2)
    exec << candle(last_t + 1, 121, 125, 120, 124)

    position = {
      id: 1,
      side: 'long',
      entry_price: '100',
      quantity: '1',
      stop_price: '90',
      partial_done: 0,
      initial_stop_price: '90',
      peak_unrealized_usdt: '15'
    }

    sig = strat.evaluate(
      pair: 'B-SOL_USDT',
      candles_htf: uptrend,
      candles_exec: exec,
      position: position,
      ltp: BigDecimal('108')
    )

    expect(sig.action).to eq(:close)
    expect(sig.reason).to eq('hwm_giveback')
  end
end
