# frozen_string_literal: true

RSpec.describe CoindcxBot::SmcSetup::PlannerContext do
  def dto_candles(n)
    Array.new(n) do |i|
      CoindcxBot::Dto::Candle.new(
        time: Time.utc(2024, 6, 1) + (i * 900),
        open: 100 + i * 0.1,
        high: 101 + i * 0.1,
        low: 99 + i * 0.1,
        close: 100.5 + i * 0.1,
        volume: 1000 + i
      )
    end
  end

  let(:config) do
    CoindcxBot::Config.new(
      minimal_bot_config(
        smc_setup: {
          enabled: true,
          planner_enabled: true,
          planner_min_candles: 30,
          planner_ohlcv_tail: 8
        },
        strategy: {
          execution_resolution: '15m',
          higher_timeframe_resolution: '1h',
          smc_confluence: { min_score: 10, vp_bars: 8, smc_swing: 3, ms_swing: 3 }
        }
      )
    )
  end

  it 'builds market_state, optional features, and a short OHLCV tail per pair' do
    pair = 'B-SOL_USDT'
    candles = dto_candles(40)

    ctx = described_class.build(
      pairs: [pair],
      candles_by_pair: { pair => candles },
      open_count: 0,
      exec_resolution: '15m',
      htf_resolution: '1h',
      strategy_cfg: config.strategy,
      config: config
    )

    expect(ctx[:pairs]).to eq([pair])
    expect(ctx[:candles_by_pair][pair].size).to eq(8)
    expect(ctx[:market_state_by_pair][pair]).to be_a(Hash)
    expect(ctx[:market_state_by_pair][pair]).not_to have_key(:error)
    expect(ctx[:features_by_pair][pair]).to be_a(Hash)
  end

  it 'reports insufficient_candles when below planner_min_candles' do
    pair = 'B-SOL_USDT'
    ctx = described_class.build(
      pairs: [pair],
      candles_by_pair: { pair => dto_candles(10) },
      open_count: 0,
      exec_resolution: '15m',
      htf_resolution: '1h',
      strategy_cfg: config.strategy,
      config: config
    )

    expect(ctx[:market_state_by_pair][pair][:error]).to eq('insufficient_candles')
  end

  it 'normalizes hash OHLCV rows without timestamps' do
    pair = 'B-ETH_USDT'
    rows = Array.new(35) do |i|
      { o: 2000 + i, h: 2001 + i, l: 1999 + i, c: 2000.5 + i, v: 500 }
    end

    ctx = described_class.build(
      pairs: [pair],
      candles_by_pair: { pair => rows },
      open_count: 0,
      exec_resolution: '15m',
      htf_resolution: '1h',
      strategy_cfg: config.strategy,
      config: config
    )

    expect(ctx[:market_state_by_pair][pair]).not_to have_key(:error)
    expect(ctx[:candles_by_pair][pair].first).to include(:o, :h, :l, :c, :t)
  end
end
