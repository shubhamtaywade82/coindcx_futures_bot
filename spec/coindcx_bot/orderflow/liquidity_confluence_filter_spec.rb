# frozen_string_literal: true

require 'logger'

RSpec.describe CoindcxBot::Orderflow::LiquidityConfluenceFilter do
  let(:bus) { CoindcxBot::Core::EventBus.new }
  let(:pair) { 'B-SOL_USDT' }
  let(:logger) { Logger.new(File::NULL) }

  let(:config) do
    CoindcxBot::Config.new(
      minimal_bot_config(
        orderflow: {
          confluence: {
            enabled: true,
            max_context_age_ms: 120_000,
            sweep_window_ms: 60_000,
            entry_to_wall_bps: 15,
            veto_min_score: 1.5,
            iceberg_proximity_bps: 10,
            zone_distance_bps: 50,
            void_proximity_bps: 30,
            imbalance_strict: false,
            rules: {
              wall_in_path_veto: true,
              sweep_confirms: true,
              iceberg_caution: true,
              zone_alignment: true,
              void_caution: true,
              imbalance_alignment: true
            }
          }
        }
      )
    )
  end

  let(:store) { CoindcxBot::Orderflow::LiquidityContextStore.new(bus: bus, divergence_lookup: ->(_) { nil }) }
  let(:filter) { described_class.new(context_store: store, config: config, logger: logger, bus: bus) }

  before { store }

  let(:open_long) do
    CoindcxBot::Strategy::Signal.new(
      action: :open_long, pair: pair, side: :long, stop_price: BigDecimal('90'), reason: 'test', metadata: {}
    )
  end

  let(:open_short) do
    CoindcxBot::Strategy::Signal.new(
      action: :open_short, pair: pair, side: :short, stop_price: BigDecimal('110'), reason: 'test', metadata: {}
    )
  end

  def feed_wall_ask(price:, score:, ts:)
    bus.publish(
      :'liquidity.wall.detected',
      { pair: pair, source: :binance, side: :ask, price: price.to_s, size: '10', score: score, ts: ts, price_band: price.to_s }
    )
  end

  it 'passes through unchanged when no Binance context has been seen' do
    out = filter.filter(open_long, entry_price: BigDecimal('100'))
    expect(out).to equal(open_long)
  end

  it 'passes through when context is stale' do
    t0 = (Time.now.to_f * 1000).to_i - 200_000
    bus.publish(:orderflow_imbalance, { pair: pair, value: 0.5, bias: :bearish, depth: 5, source: :binance, ts: t0 })
    out = filter.filter(open_long, entry_price: BigDecimal('100'))
    expect(out).to equal(open_long)
  end

  it 'vetoes open_long when ask wall is in path with sufficient score' do
    ts = (Time.now.to_f * 1000).to_i
    feed_wall_ask(price: '100.1', score: 2.0, ts: ts)
    out = filter.filter(open_long, entry_price: BigDecimal('100'))
    expect(out.action).to eq(:hold)
    expect(out.reason).to eq('wall_in_path')
    expect(out.metadata[:liquidity][:veto_rule]).to eq(:wall_in_path)
  end

  it 'annotates sweep_confirm for open_long on recent bid sweep' do
    ts = (Time.now.to_f * 1000).to_i
    bus.publish(
      :'liquidity.sweep.detected',
      { pair: pair, source: :binance, side: :bid, levels_swept: 4, notional: BigDecimal('2'), ts: ts }
    )
    out = filter.filter(open_long, entry_price: BigDecimal('100'))
    expect(out.action).to eq(:open_long)
    expect(out.metadata[:liquidity][:sweep_confirm]).to be true
  end

  it 'vetoes open_long on ask-side iceberg proximity' do
    ts = (Time.now.to_f * 1000).to_i
    bus.publish(
      :'liquidity.iceberg.suspected',
      { pair: pair, source: :binance, side: :ask, price: BigDecimal('100.05'), score: BigDecimal('1'), ts: ts }
    )
    out = filter.filter(open_long, entry_price: BigDecimal('100'))
    expect(out.action).to eq(:hold)
    expect(out.reason).to eq('iceberg_overhead')
  end

  it 'annotates zone_support when bid zone sits below entry within distance' do
    ts = (Time.now.to_f * 1000).to_i
    bus.publish(
      :'liquidity.zone.confirmed',
      { pair: pair, source: :binance, side: :bid, price_band: BigDecimal('99.5'), ts: ts }
    )
    out = filter.filter(open_long, entry_price: BigDecimal('100'))
    expect(out.metadata[:liquidity][:zone_support]).to eq(BigDecimal('99.5'))
  end

  it 'vetoes open_long when ask void sits above entry within proximity' do
    ts = (Time.now.to_f * 1000).to_i
    bus.publish(
      :'liquidity.void.detected',
      { pair: pair, source: :binance, side: :ask, void_start: BigDecimal('100.02'), void_end: BigDecimal('100.04'),
        ts: ts }
    )
    out = filter.filter(open_long, entry_price: BigDecimal('100'))
    expect(out.action).to eq(:hold)
    expect(out.reason).to eq('void_above')
  end

  it 'annotates imbalance_warning without hold when not strict' do
    ts = (Time.now.to_f * 1000).to_i
    bus.publish(:orderflow_imbalance, { pair: pair, value: -0.5, bias: :bearish, depth: 5, source: :binance, ts: ts })
    out = filter.filter(open_long, entry_price: BigDecimal('100'))
    expect(out.action).to eq(:open_long)
    expect(out.metadata[:liquidity][:imbalance_warning]).to be true
  end

  it 'mirrors wall veto for open_short with bid wall below entry' do
    ts = (Time.now.to_f * 1000).to_i
    bus.publish(
      :'liquidity.wall.detected',
      { pair: pair, source: :binance, side: :bid, price: '99.9', size: '10', score: 2.0, ts: ts, price_band: '99.9' }
    )
    out = filter.filter(open_short, entry_price: BigDecimal('100'))
    expect(out.action).to eq(:hold)
    expect(out.reason).to eq('wall_in_path')
  end

  it 'publishes veto bus event once per transition' do
    vetoes = []
    bus.subscribe(:'liquidity.confluence.veto') { |p| vetoes << p }
    ts = (Time.now.to_f * 1000).to_i
    feed_wall_ask(price: '100.1', score: 2.0, ts: ts)
    filter.filter(open_long, entry_price: BigDecimal('100'))
    filter.filter(open_long, entry_price: BigDecimal('100'))
    expect(vetoes.size).to eq(1)
    expect(vetoes.first[:rule]).to eq(:wall_in_path)
  end

  context 'imbalance_strict' do
    let(:config) do
      CoindcxBot::Config.new(
        minimal_bot_config(
          orderflow: {
            confluence: {
              enabled: true,
              max_context_age_ms: 120_000,
              imbalance_strict: true,
              rules: { imbalance_alignment: true, wall_in_path_veto: false, sweep_confirms: false,
                         iceberg_caution: false, zone_alignment: false, void_caution: false }
            }
          }
        )
      )
    end

    it 'downgrades to hold on disagreement' do
      ts = (Time.now.to_f * 1000).to_i
      bus.publish(:orderflow_imbalance, { pair: pair, value: -0.5, bias: :bearish, depth: 5, source: :binance, ts: ts })
      out = filter.filter(open_long, entry_price: BigDecimal('100'))
      expect(out.action).to eq(:hold)
      expect(out.reason).to eq('imbalance_disagreement')
    end
  end
end
