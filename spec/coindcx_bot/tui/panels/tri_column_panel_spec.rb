# frozen_string_literal: true

require 'bigdecimal'

RSpec.describe CoindcxBot::Tui::Panels::TriColumnPanel do
  let(:output) { StringIO.new }
  let(:broker_double) { double('broker', paper?: false, tui_working_orders: []) }
  let(:snapshot) do
    CoindcxBot::Core::Engine::Snapshot.new(
      pairs: %w[B-SOL_USDT],
      ticks: { 'B-SOL_USDT' => { price: '150.0', at: Time.now } },
      positions: [
        { id: 1, pair: 'B-SOL_USDT', side: 'long', quantity: '0.1', entry_price: '140.0', stop_price: '130' }
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
  let(:engine) { double('engine', snapshot: snapshot, broker: broker_double) }
  let(:panel) do
    described_class.new(engine: engine, symbols: %w[B-SOL_USDT], origin_row: 0, output: output)
  end

  before { allow(TTY::Screen).to receive(:width).and_return(120) }

  it 'renders table borders and position summary' do
    panel.render
    s = output.string
    expect(s).to include('┌')
    expect(s).to include('TICKERS')
    expect(s).to include('POSITIONS')
    expect(s).to include('ORDERS')
    expect(s).to include('B-SOL_USDT')
    expect(s).to include('150.00')
    expect(s).to include('ENTRY')
    expect(s).to include('SELL')
    expect(s).to include('PENDING')
  end
end
