# frozen_string_literal: true

require 'bigdecimal'

RSpec.describe CoindcxBot::Tui::Panels::DeskFuturesGridPanel do
  let(:tick_store) { CoindcxBot::Tui::TickStore.new }
  let(:order_book_store) { CoindcxBot::Tui::OrderBookStore.new }
  let(:output) { StringIO.new }
  let(:broker_double) { double('broker', paper?: false, tui_working_orders: []) }
  let(:snapshot) do
    CoindcxBot::Core::Engine::Snapshot.new(
      pairs: %w[B-SOL_USDT],
      ticks: { 'B-SOL_USDT' => { price: '150.0', at: Time.now } },
      positions: [
        { pair: 'B-SOL_USDT', side: 'long', quantity: '0.1', entry_price: '140.0', stop_price: '130.0' }
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
      recent_events: [{ ts: 1_700_000_000, type: 'tick', payload: { pair: 'B-SOL_USDT' } }],
      working_orders: [],
      ws_last_tick_ms_ago: 5,
      strategy_last_by_pair: { 'B-SOL_USDT' => { action: :hold, reason: 'ok' } },
      regime: CoindcxBot::Regime::TuiState.disabled,
      smc_setup: CoindcxBot::SmcSetup::TuiOverlay::DISABLED,
      exchange_positions: [],
      exchange_positions_error: nil,
      exchange_positions_fetched_at: nil,
      live_tui_metrics: {}
    )
  end
  let(:config) do
    instance_double(
      CoindcxBot::Config,
      risk: { max_daily_loss_inr: 1500, max_leverage: 10 },
      strategy: { name: 'trend' },
      inr_per_usdt: BigDecimal('83'),
      resolved_max_daily_loss_inr: BigDecimal('1500'),
      execution: { order_defaults: { leverage: 5 } },
      trading_mode_label: 'SWING',
      scalper_mode?: false,
      tui_exchange_positions_enabled?: false
    )
  end
  let(:engine) { double('engine', snapshot: snapshot, broker: broker_double, config: config) }
  let(:panel) do
    described_class.new(
      engine: engine,
      tick_store: tick_store,
      order_book_store: order_book_store,
      symbols: %w[B-SOL_USDT],
      focus_pair_proc: -> { 'B-SOL_USDT' },
      origin_row: 0,
      output: output
    )
  end

  before do
    allow(engine).to receive(:ws_feed_stale?).and_return(false)
    tick_store.update(symbol: 'B-SOL_USDT', ltp: 150.0, bid: 149.9, ask: 150.1)
    order_book_store.update(
      pair: 'B-SOL_USDT',
      bids: [{ 'price' => '149', 'quantity' => '1' }],
      asks: [{ 'price' => '151', 'quantity' => '2' }]
    )
  end

  describe '#render' do
    it 'draws the futures grid without raising' do
      panel.render
      s = output.string
      expect(s).to include('BOOK')
      expect(s).to include('POSITIONS')
    end

    it 'shows full book quantities when the column is wide enough (no 5-char cap)' do
      order_book_store.update(
        pair: 'B-SOL_USDT',
        bids: [{ 'price' => '82.24', 'quantity' => '5189.12' }],
        asks: [{ 'price' => '82.34', 'quantity' => '2103.45' }]
      )
      panel.render
      s = output.string.gsub(/\e\[[0-9;]*m/, '')
      expect(s).to include('5189')
      expect(s).to include('2103')
      expect(s).not_to match(/5189\.…|2103\.…/)
    end
  end

  describe 'book column splits' do
    it 'gives quantity more width as the book column grows' do
      _px_narrow, qty_narrow = panel.send(:book_column_splits, 20)
      _px_wide, qty_wide = panel.send(:book_column_splits, 30)
      expect(qty_wide).to be > qty_narrow
    end
  end

  describe '#row_count' do
    it 'matches header + data + footer height' do
      expect(panel.row_count).to eq(11)
    end
  end
end
