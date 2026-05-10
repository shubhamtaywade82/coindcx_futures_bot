# frozen_string_literal: true

require 'bigdecimal'

RSpec.describe CoindcxBot::MarketData::DivergenceMonitor do
  let(:bus) { CoindcxBot::Core::EventBus.new }
  let(:pair) { 'B-SOL_USDT' }
  let(:guard) { CoindcxBot::Risk::DivergenceGuard.new(max_bps: BigDecimal('50'), max_lag_ms: 60_000) }
  let(:logger) { nil }

  let(:monitor) do
    described_class.new(
      bus: bus,
      guard: guard,
      pair: pair,
      binance_symbol: 'SOLUSDT',
      ws_gateway: nil,
      stub_coindcx: false,
      logger: logger,
      check_interval_ms: 50
    )
  end

  def publish_bus
    captured = []
    bus.subscribe(described_class::EVENT_OK) { |p| captured << [:ok, p] }
    bus.subscribe(described_class::EVENT_EXCEEDED) { |p| captured << [:exceeded, p] }
    bus.subscribe(described_class::EVENT_RECOVERED) { |p| captured << [:recovered, p] }
    captured
  end

  def wall_ms
    (Time.now.to_f * 1000).to_i
  end

  it 'emits ok once when first check passes after both legs are fed' do
    log = publish_bus
    t = wall_ms
    monitor.start
    monitor.on_binance_book_ticker(best_bid: BigDecimal('99'), best_ask: BigDecimal('101'), ts: t)
    monitor.feed_coindcx_mid(mid: BigDecimal('100'), ts: t)
    sleep(0.15)
    monitor.stop
    expect(log.map(&:first)).to eq([:ok])
    expect(log.first[1][:pair]).to eq(pair)
  end

  it 'emits exceeded once on ok to err then dedupes while err persists' do
    log = publish_bus
    t = wall_ms
    monitor.start
    monitor.on_binance_book_ticker(best_bid: BigDecimal('99'), best_ask: BigDecimal('101'), ts: t)
    monitor.feed_coindcx_mid(mid: BigDecimal('100'), ts: t)
    sleep(0.12)
    t2 = wall_ms
    guard.update_binance_mid(symbol: 'SOLUSDT', mid: BigDecimal('200'), ts: t2)
    monitor.feed_coindcx_mid(mid: BigDecimal('100'), ts: t2)
    monitor.send(:tick_check)
    monitor.send(:tick_check)
    monitor.stop
    exceeded = log.select { |e| e[0] == :exceeded }
    expect(exceeded.size).to eq(1)
    expect(exceeded.first[1][:reason]).to eq(:max_bps_exceeded)
  end

  it 'emits recovered once when returning from err to ok' do
    log = publish_bus
    t = wall_ms
    monitor.start
    monitor.on_binance_book_ticker(best_bid: BigDecimal('99'), best_ask: BigDecimal('101'), ts: t)
    monitor.feed_coindcx_mid(mid: BigDecimal('100'), ts: t)
    sleep(0.12)
    t_bad = wall_ms
    guard.update_binance_mid(symbol: 'SOLUSDT', mid: BigDecimal('200'), ts: t_bad)
    monitor.feed_coindcx_mid(mid: BigDecimal('100'), ts: t_bad)
    monitor.send(:tick_check)
    t_ok = wall_ms
    guard.update_binance_mid(symbol: 'SOLUSDT', mid: BigDecimal('100'), ts: t_ok)
    monitor.feed_coindcx_mid(mid: BigDecimal('100'), ts: t_ok)
    monitor.send(:tick_check)
    monitor.send(:tick_check)
    monitor.stop
    expect(log.map(&:first)).to eq([:ok, :exceeded, :recovered])
  end

  it 'does not emit exceeded for missing_data while warming up' do
    log = publish_bus
    monitor.start
    sleep(0.12)
    monitor.stop
    expect(log).to be_empty
  end
end
