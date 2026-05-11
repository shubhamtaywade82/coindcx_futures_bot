# frozen_string_literal: true

require 'bigdecimal'

RSpec.describe CoindcxBot::Risk::DivergenceGuard do
  let(:guard) { described_class.new(max_bps: BigDecimal('25'), max_lag_ms: 1_500) }
  let(:pair) { 'B-SOL_USDT' }
  let(:now) { 2_000_000 }

  def seed_ok_leg(now_ms: now)
    guard.update_binance_mid(symbol: 'SOLUSDT', mid: BigDecimal('100'), ts: now_ms - 50)
    guard.update_coindcx_mid(pair: pair, mid: BigDecimal('100.05'), ts: now_ms - 60)
  end

  it 'returns ok with bps and age_ms when within limits' do
    seed_ok_leg
    r = guard.check(pair: pair, now_ms: now)
    expect(r).to be_ok
    expect(r.value[:bps]).to be_a(BigDecimal)
    expect(r.value[:age_ms]).to eq(now - (now - 50))
  end

  it 'returns max_bps_exceeded when spread is too wide' do
    guard.update_binance_mid(symbol: 'SOLUSDT', mid: BigDecimal('110'), ts: now - 100)
    guard.update_coindcx_mid(pair: pair, mid: BigDecimal('100'), ts: now - 100)
    r = guard.check(pair: pair, now_ms: now)
    expect(r).to be_failure
    expect(r.code).to eq(:max_bps_exceeded)
    expect(r.value[:reason]).to eq(:max_bps_exceeded)
    expect(r.value[:bps]).to be > BigDecimal('25')
  end

  it 'returns coindcx_stale when CoinDCX ts is too old' do
    guard.update_binance_mid(symbol: 'SOLUSDT', mid: BigDecimal('100'), ts: now - 100)
    guard.update_coindcx_mid(pair: pair, mid: BigDecimal('100'), ts: now - 2_000)
    r = guard.check(pair: pair, now_ms: now)
    expect(r).to be_failure
    expect(r.code).to eq(:coindcx_stale)
  end

  it 'returns binance_stale when Binance ts is too old' do
    guard.update_binance_mid(symbol: 'SOLUSDT', mid: BigDecimal('100'), ts: now - 2_000)
    guard.update_coindcx_mid(pair: pair, mid: BigDecimal('100'), ts: now - 100)
    r = guard.check(pair: pair, now_ms: now)
    expect(r).to be_failure
    expect(r.code).to eq(:binance_stale)
  end

  it 'returns missing_data before both legs exist' do
    guard.update_binance_mid(symbol: 'SOLUSDT', mid: BigDecimal('100'), ts: now - 10)
    r = guard.check(pair: pair, now_ms: now)
    expect(r).to be_failure
    expect(r.code).to eq(:missing_data)
  end

  it 'caches last mids per pair in last_snapshot' do
    seed_ok_leg(now_ms: 5_000_000)
    guard.check(pair: pair, now_ms: 5_000_000)
    snap = guard.last_snapshot(pair)
    expect(snap[:binance_mid]).to eq(BigDecimal('100'))
    expect(snap[:coindcx_mid]).to eq(BigDecimal('100.05'))
  end

  it 'is safe under concurrent updates and checks' do
    t = 10_000_000
    threads = Array.new(8) do |i|
      Thread.new do
        20.times do |j|
          guard.update_binance_mid(symbol: 'SOLUSDT', mid: BigDecimal((100 + i + j).to_s), ts: t + j)
          guard.update_coindcx_mid(pair: pair, mid: BigDecimal((100 + j).to_s), ts: t + j)
          guard.check(pair: pair, now_ms: t + 500)
        end
      end
    end
    threads.each(&:join)
    expect(guard.last_snapshot(pair)).to include(:binance_mid, :coindcx_mid, :binance_ts, :coindcx_ts)
  end
end
