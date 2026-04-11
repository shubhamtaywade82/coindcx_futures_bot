# frozen_string_literal: true

RSpec.describe CoindcxBot::Tui::Panels::DeskMarketDepthPanel do
  let(:tick_store) { CoindcxBot::Tui::TickStore.new }
  let(:output) { StringIO.new }
  let(:broker_double) { double('broker', paper?: false, tui_working_orders: []) }
  let(:snapshot) do
    CoindcxBot::Core::Engine::Snapshot.new(
      pairs: %w[B-SOL_USDT],
      ticks: {},
      positions: [],
      paused: false,
      kill_switch: false,
      stale: false,
      last_error: nil,
      daily_pnl: 0,
      running: true,
      dry_run: true,
      stale_tick_seconds: 45,
      paper_metrics: {},
      capital_inr: nil,
      recent_events: [],
      working_orders: [],
      ws_last_tick_ms_ago: 1,
      strategy_last_by_pair: {},
      regime: CoindcxBot::Regime::TuiState.disabled
    )
  end
  let(:config) do
    instance_double(
      CoindcxBot::Config,
      risk: { max_daily_loss_inr: 1500 },
      strategy: { name: 'trend' },
      resolved_max_daily_loss_inr: BigDecimal('1500'),
      execution: { order_defaults: {} },
      trading_mode_label: 'SWING',
      scalper_mode?: false
    )
  end
  let(:engine) { double('engine', snapshot: snapshot, broker: broker_double, config: config) }
  let(:panel) do
    described_class.new(
      engine: engine,
      tick_store: tick_store,
      symbols: %w[B-SOL_USDT],
      origin_row: 0,
      output: output
    )
  end

  before do
    allow(CoindcxBot::Tui::TermWidth).to receive(:columns).and_return(100)
    allow(engine).to receive(:ws_feed_stale?).with('B-SOL_USDT').and_return(false)
  end

  it 'renders L1 headers and placeholder bid/ask when no order book is wired' do
    tick_store.update(symbol: 'B-SOL_USDT', ltp: 142.5, change_pct: 1.23)
    panel.render
    s = output.string
    expect(s).to include('MARKET DEPTH (L1)')
    expect(s).to include('B-SOL_USDT')
    expect(s).to include('BID')
    expect(s).to include('SPREAD')
    expect(s).to include('+1.23%')
  end

  it 'keeps STATE column distinct without sprintf/ANSI width bleed' do
    tick_store.update(symbol: 'B-SOL_USDT', ltp: 142.5, change_pct: 1.23)
    panel.render
    plain = output.string.gsub(/\e\[[0-9;]*m/, '')
    expect(plain).to include('LIVE')
    expect(plain).not_to include('LIVEE')
  end

  it 'marks STALE when the engine reports a stale WebSocket feed' do
    tick_store.update(symbol: 'B-SOL_USDT', ltp: 100.0, change_pct: 0.0)
    allow(engine).to receive(:ws_feed_stale?).with('B-SOL_USDT').and_return(true)
    panel.render
    expect(output.string).to match(/STALE/)
  end
end
