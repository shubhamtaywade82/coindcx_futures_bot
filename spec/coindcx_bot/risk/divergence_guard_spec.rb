# frozen_string_literal: true

require 'bigdecimal'

RSpec.describe CoindcxBot::Risk::DivergenceGuard do
  let(:guard) { described_class.new(max_bps: BigDecimal('25'), max_lag_ms: 1_500) }

  it 'returns ok when within bps and lag bounds' do
    now = 2_000_000
    r = guard.check(
      symbol: 'B-BTC_USDT',
      binance_mid: BigDecimal('100'),
      coindcx_mid: BigDecimal('100.1'),
      coindcx_ts: now - 100,
      now_ms: now
    )
    expect(r).to be_ok
    expect(r.value[:bps]).to be < BigDecimal('25')
  end

  it 'returns err when bps exceed limit' do
    r = guard.check(
      symbol: 'B-BTC_USDT',
      binance_mid: BigDecimal('110'),
      coindcx_mid: BigDecimal('100'),
      coindcx_ts: 1_000_000,
      now_ms: 1_000_500
    )
    expect(r).to be_failure
    expect(r.code).to eq(:divergence_bps)
  end

  it 'returns err when CoinDCX timestamp is stale' do
    r = guard.check(
      symbol: 'B-BTC_USDT',
      binance_mid: BigDecimal('100'),
      coindcx_mid: BigDecimal('100'),
      coindcx_ts: 1_000_000,
      now_ms: 1_002_000
    )
    expect(r).to be_failure
    expect(r.code).to eq(:stale_coindcx)
  end

  it 'caches last mids per symbol' do
    t = 5_000_000
    guard.check(symbol: 'P', binance_mid: BigDecimal('2'), coindcx_mid: BigDecimal('2'), coindcx_ts: t, now_ms: t)
    snap = guard.last_snapshot('P')
    expect(snap[:binance_mid]).to eq(BigDecimal('2'))
  end
end
