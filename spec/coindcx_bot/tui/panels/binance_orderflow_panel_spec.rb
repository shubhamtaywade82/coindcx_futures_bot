# frozen_string_literal: true

require 'bigdecimal'

RSpec.describe CoindcxBot::Tui::Panels::BinanceOrderflowPanel do
  let(:bus) { CoindcxBot::Core::EventBus.new }
  let(:output) { StringIO.new }
  let(:engine) do
    double(
      'engine',
      snapshot: CoindcxBot::Core::Engine::Snapshot.new(
        pairs: %w[B-SOL_USDT],
        ticks: {},
        positions: [],
        paused: false,
        kill_switch: false,
        stale: false,
        last_error: nil,
        daily_pnl: BigDecimal('0'),
        running: true,
        dry_run: false,
        stale_tick_seconds: 45,
        paper_metrics: {},
        capital_inr: BigDecimal('50_000'),
        recent_events: [],
        working_orders: [],
        ws_last_tick_ms_ago: 10,
        strategy_last_by_pair: {},
        regime: CoindcxBot::Regime::TuiState.disabled,
        smc_setup: CoindcxBot::SmcSetup::TuiOverlay::DISABLED,
        exchange_positions: [],
        exchange_positions_error: nil,
        exchange_positions_fetched_at: nil,
        live_tui_metrics: {},
        ai_analysis: {}
      )
    )
  end

  subject(:panel) do
    described_class.new(
      bus: bus,
      engine: engine,
      origin_row: 0,
      focus_pair_proc: -> { 'B-SOL_USDT' },
      output: output,
      visible: true
    )
  end

  before { panel }

  def publish_wall(side, price, score)
    bus.publish(
      :'liquidity.wall.detected',
      {
        source: :binance,
        pair: 'B-SOL_USDT',
        symbol: 'B-SOL_USDT',
        side: side,
        price: price,
        size: BigDecimal('120'),
        score: score,
        ts: (Time.now.to_f * 1000).to_i
      }
    )
  end

  it 'renders BINANCE ORDERFLOW header and records divergence OK state' do
    bus.publish('risk.divergence.ok', { pair: 'B-SOL_USDT', bps: 1.2, age_ms: 40 })
    panel.render
    text = output.string
    expect(text).to include('BINANCE ORDERFLOW')
    div = panel.send(:instance_variable_get, :@divergence)['B-SOL_USDT']
    expect(div[:label]).to eq('OK')
    expect(div[:bps]).to eq(1.2)
  end

  it 'keeps event ring bounded and shows latest sweeps after trim' do
    10.times do |i|
      bus.publish(
        :'liquidity.sweep.detected',
        {
          source: :binance,
          pair: 'B-SOL_USDT',
          symbol: 'B-SOL_USDT',
          side: :bid,
          levels_swept: 3,
          notional: BigDecimal((i + 1).to_s),
          ts: i
        }
      )
    end

    panel.render
    ring = panel.send(:instance_variable_get, :@event_ring)
    expect(ring.size).to eq(described_class::EVENT_RING)
    expect(ring.last[:kind]).to eq(:sweep)
    expect(ring.last[:ev][:notional]).to eq(BigDecimal('10'))
    expect(output.string).to include('BINANCE ORDERFLOW')
  end

  it 'ignores CoinDCX-sourced wall events' do
    bus.publish(
      :'liquidity.wall.detected',
      {
        source: :coindcx,
        pair: 'B-SOL_USDT',
        symbol: 'B-SOL_USDT',
        side: :bid,
        price: '99',
        size: '9000',
        score: 50.0,
        ts: 1
      }
    )
    publish_wall(:bid, '100', 3.0)
    panel.render
    expect(output.string).not_to include('99')
  end
end
