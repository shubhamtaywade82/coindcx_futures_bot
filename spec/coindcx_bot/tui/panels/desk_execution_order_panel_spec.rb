# frozen_string_literal: true

require 'bigdecimal'

RSpec.describe CoindcxBot::Tui::Panels::DeskExecutionOrderPanel do
  let(:tick_store) { CoindcxBot::Tui::TickStore.new }
  let(:output) { StringIO.new }
  let(:broker_double) { double('broker', paper?: false, tui_working_orders: []) }
  let(:snapshot) do
    CoindcxBot::Core::Engine::Snapshot.new(
      pairs: %w[B-SOL_USDT],
      ticks: { 'B-SOL_USDT' => { price: '150.0', at: Time.now } },
      positions: [
        { pair: 'B-SOL_USDT', side: 'long', quantity: '0.1', entry_price: '140.0' }
      ],
      paused: false,
      kill_switch: false,
      stale: false,
      last_error: nil,
      daily_pnl: BigDecimal('0'),
      running: true,
      dry_run: true,
      stale_tick_seconds: 45,
      paper_metrics: {},
      capital_inr: nil,
      recent_events: [],
      working_orders: [
        { id: 9, pair: 'B-SOL_USDT', side: 'sell', order_type: 'limit', quantity: '0.1', limit_price: '160',
          stop_price: nil }
      ],
      ws_last_tick_ms_ago: 5
    )
  end
  let(:config) do
    instance_double(
      CoindcxBot::Config,
      risk: { max_daily_loss_inr: 1500 },
      strategy: { name: 'trend' },
      resolved_max_daily_loss_inr: BigDecimal('1500')
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
    allow(TTY::Screen).to receive(:width).and_return(120)
    tick_store.update(symbol: 'B-SOL_USDT', ltp: 150.0, change_pct: 0.5)
    allow(engine).to receive(:ws_feed_stale?).and_return(false)
  end

  it 'renders execution matrix and order flow frames' do
    panel.render
    s = output.string
    expect(s).to include('┌')
    expect(s).to include('EXECUTION MATRIX')
    expect(s).to include('ORDER FLOW')
    expect(s).to include('B-SOL_USDT')
    expect(s).to include('LONG')
    expect(s).to include('LIM')
    expect(s).to include('ACTIVE')
  end
end
