# frozen_string_literal: true

RSpec.describe CoindcxBot::Orderflow::EventDedup do
  let(:clock_value) { [1_000] }
  let(:clock) { -> { clock_value.first } }
  let(:dedup) { described_class.new(clock: clock) }

  describe '#emit_if_changed' do
    it 'fires the block on first call and skips when state is unchanged' do
      calls = 0
      dedup.emit_if_changed(key: 'pair', state: :bullish) { calls += 1 }
      dedup.emit_if_changed(key: 'pair', state: :bullish) { calls += 1 }
      dedup.emit_if_changed(key: 'pair', state: :bullish) { calls += 1 }

      expect(calls).to eq(1)
    end

    it 'fires again when the cached state changes' do
      calls = 0
      dedup.emit_if_changed(key: 'pair', state: :bullish) { calls += 1 }
      dedup.emit_if_changed(key: 'pair', state: :bearish) { calls += 1 }
      dedup.emit_if_changed(key: 'pair', state: :bearish) { calls += 1 }

      expect(calls).to eq(2)
    end

    it 'fires after ttl expires even when state is unchanged' do
      calls = 0
      dedup.emit_if_changed(key: 'pair', state: :neutral, ttl_ms: 500) { calls += 1 }
      dedup.emit_if_changed(key: 'pair', state: :neutral, ttl_ms: 500) { calls += 1 }
      clock_value[0] = 1_600
      dedup.emit_if_changed(key: 'pair', state: :neutral, ttl_ms: 500) { calls += 1 }

      expect(calls).to eq(2)
    end
  end

  describe '#emit_if_threshold_crossed' do
    it 'fires on first observation and after sufficient delta' do
      emitted = []
      dedup.emit_if_threshold_crossed(key: 'imb', value: 0.10, prev: nil, pct: 0.5) { emitted << 0.10 }
      dedup.emit_if_threshold_crossed(key: 'imb', value: 0.12, prev: nil, pct: 0.5) { emitted << 0.12 }
      dedup.emit_if_threshold_crossed(key: 'imb', value: 0.20, prev: nil, pct: 0.5) { emitted << 0.20 }

      expect(emitted).to eq([0.10, 0.20])
    end

    it 'uses an explicitly provided prev when present' do
      emitted = []
      dedup.emit_if_threshold_crossed(key: 'imb', value: 0.30, prev: 0.20, pct: 0.5) { emitted << :explicit }

      expect(emitted).to eq([])
    end
  end

  describe '#emit_if_cooled' do
    it 'suppresses repeats within the cooldown window' do
      emitted = []
      dedup.emit_if_cooled(key: 'sweep', cooldown_ms: 1_000) { emitted << :a }
      clock_value[0] = 1_500
      dedup.emit_if_cooled(key: 'sweep', cooldown_ms: 1_000) { emitted << :b }
      clock_value[0] = 2_500
      dedup.emit_if_cooled(key: 'sweep', cooldown_ms: 1_000) { emitted << :c }

      expect(emitted).to eq(%i[a c])
    end
  end
end

RSpec.describe CoindcxBot::Orderflow::WallDedup do
  let(:clock_value) { [1_000] }
  let(:clock) { -> { clock_value.first } }
  let(:config) do
    instance_double(
      'Config',
      orderflow_section: {
        walls: {
          dedup: {
            price_band_ticks: 1,
            tick_size: '0.01',
            size_change_pct: 0.25,
            removal_grace_ms: 500,
          },
        },
      }
    )
  end
  let(:wall_dedup) { described_class.new(config: config, clock: clock) }

  def wall(side, price, size, score: 1.0)
    { side: side, price: BigDecimal(price), size: BigDecimal(size.to_s), score: score }
  end

  it 'emits detected exactly once when walls are unchanged across snapshots' do
    detected = []
    walls = [wall(:bid, '100', 5_000), wall(:ask, '101', 4_000)]

    3.times do
      wall_dedup.process(pair: 'B-SOL_USDT', source: :binance, walls: walls, ts_ms: clock.call) do |kind, payload|
        detected << [kind, payload[:side], payload[:price]]
      end
      clock_value[0] += 100
    end

    expect(detected.count { |k, _, _| k == :detected }).to eq(2)
  end

  it 'emits detected when size moves more than size_change_pct' do
    detected = []
    wall_dedup.process(pair: 'P', source: :binance, walls: [wall(:bid, '100', 1_000)], ts_ms: 1_000) { |k, p| detected << [k, p[:size]] }
    wall_dedup.process(pair: 'P', source: :binance, walls: [wall(:bid, '100', 1_100)], ts_ms: 1_100) { |k, p| detected << [k, p[:size]] }
    wall_dedup.process(pair: 'P', source: :binance, walls: [wall(:bid, '100', 1_500)], ts_ms: 1_200) { |k, p| detected << [k, p[:size]] }

    expect(detected.map { |k, _| k }).to eq(%i[detected detected])
    expect(detected.last.last).to eq(BigDecimal('1500'))
  end

  it 'emits removed only after removal_grace_ms elapses' do
    events = []
    wall_dedup.process(pair: 'P', source: :binance, walls: [wall(:bid, '100', 1_000)], ts_ms: 1_000) { |k, p| events << [k, p[:price]] }
    wall_dedup.process(pair: 'P', source: :binance, walls: [], ts_ms: 1_200) { |k, p| events << [k, p[:price]] }
    wall_dedup.process(pair: 'P', source: :binance, walls: [], ts_ms: 1_400) { |k, p| events << [k, p[:price]] }
    wall_dedup.process(pair: 'P', source: :binance, walls: [], ts_ms: 1_900) { |k, p| events << [k, p[:price]] }

    kinds = events.map(&:first)
    expect(kinds).to eq(%i[detected removed])
  end

  it 'cancels pending removal when the wall reappears within grace' do
    events = []
    wall_dedup.process(pair: 'P', source: :binance, walls: [wall(:bid, '100', 1_000)], ts_ms: 1_000) { |k, _p| events << k }
    wall_dedup.process(pair: 'P', source: :binance, walls: [], ts_ms: 1_200) { |k, _p| events << k }
    wall_dedup.process(pair: 'P', source: :binance, walls: [wall(:bid, '100', 1_000)], ts_ms: 1_300) { |k, _p| events << k }
    wall_dedup.process(pair: 'P', source: :binance, walls: [wall(:bid, '100', 1_000)], ts_ms: 1_900) { |k, _p| events << k }

    expect(events).to eq([:detected])
  end

  it 'returns true when changes occur and false when nothing happens' do
    walls = [wall(:bid, '100', 1_000)]
    silent = ->(_kind, _payload) {}
    first = wall_dedup.process(pair: 'P', source: :binance, walls: walls, ts_ms: 1_000, &silent)
    same  = wall_dedup.process(pair: 'P', source: :binance, walls: walls, ts_ms: 1_100, &silent)

    expect(first).to be(true)
    expect(same).to be(false)
  end
end

RSpec.describe CoindcxBot::Orderflow::DedupPublisher do
  let(:bus) { CoindcxBot::Core::EventBus.new }
  let(:clock_value) { [1_000] }
  let(:clock) { -> { clock_value.first } }
  let(:config) do
    instance_double(
      'Config',
      orderflow_section: {
        sweep: { dedup: { cooldown_ms: 1_000 } },
        iceberg: { dedup: { cooldown_ms: 1_000 } },
        void: { dedup: { cooldown_ms: 1_000 } },
      }
    )
  end
  let(:publisher) { described_class.new(bus: bus, config: config, clock: clock) }

  it 'forwards coindcx-source events without dedup' do
    received = []
    bus.subscribe(:'liquidity.sweep.detected') { |p| received << p[:ts] }

    3.times do |i|
      publisher.publish(:'liquidity.sweep.detected', { source: :coindcx, pair: 'P', side: :bid, ts: i })
    end

    expect(received.size).to eq(3)
  end

  it 'cools binance-source events within the cooldown window' do
    received = []
    bus.subscribe(:'liquidity.sweep.detected') { |p| received << p[:ts] }

    publisher.publish(:'liquidity.sweep.detected', { source: :binance, pair: 'P', side: :bid, ts: 1 })
    clock_value[0] = 1_500
    publisher.publish(:'liquidity.sweep.detected', { source: :binance, pair: 'P', side: :bid, ts: 2 })
    clock_value[0] = 2_500
    publisher.publish(:'liquidity.sweep.detected', { source: :binance, pair: 'P', side: :bid, ts: 3 })

    expect(received).to eq([1, 3])
  end

  it 'keys cooldown by event-specific identity (per side, per price)' do
    received = []
    bus.subscribe(:'liquidity.iceberg.suspected') { |p| received << [p[:side], p[:price]] }

    publisher.publish(:'liquidity.iceberg.suspected', { source: :binance, pair: 'P', side: :bid, price: '100' })
    publisher.publish(:'liquidity.iceberg.suspected', { source: :binance, pair: 'P', side: :ask, price: '101' })
    publisher.publish(:'liquidity.iceberg.suspected', { source: :binance, pair: 'P', side: :bid, price: '100' })

    expect(received).to eq([[:bid, '100'], [:ask, '101']])
  end

  it 'passes through events outside the cooldown table unchanged' do
    received = []
    bus.subscribe(:'liquidity.zone.confirmed') { |p| received << p[:ts] }

    publisher.publish(:'liquidity.zone.confirmed', { source: :binance, ts: 1 })
    publisher.publish(:'liquidity.zone.confirmed', { source: :binance, ts: 2 })

    expect(received).to eq([1, 2])
  end

  it 'delegates subscribe to the underlying bus' do
    received = []
    publisher.subscribe(:custom) { |p| received << p }
    bus.publish(:custom, :hello)

    expect(received).to eq([:hello])
  end
end
