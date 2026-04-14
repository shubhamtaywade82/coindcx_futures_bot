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
      ws_last_tick_ms_ago: 5,
      strategy_last_by_pair: {},
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
      risk: { max_daily_loss_inr: 1500 },
      strategy: { name: 'trend' },
      inr_per_usdt: BigDecimal('83'),
      resolved_max_daily_loss_inr: BigDecimal('1500'),
      execution: { order_defaults: {} },
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
      symbols: %w[B-SOL_USDT],
      origin_row: 0,
      output: output
    )
  end

  before do
    allow(engine).to receive(:inr_per_usdt).and_return(BigDecimal('83'))
    allow(CoindcxBot::Tui::TermWidth).to receive(:columns).and_return(120)
    tick_store.update(symbol: 'B-SOL_USDT', ltp: 150.0, change_pct: 0.5)
    allow(engine).to receive(:ws_feed_stale?).with('B-SOL_USDT').and_return(false)
  end

  describe '#render' do
    it 'renders execution matrix and order flow frames', :aggregate_failures do
      panel.render
      s = output.string
      expect(s).to include('┌')
      s_clean = s.gsub(/\e\[[\d;]*[A-Za-z]/, '').gsub(/\e[78]/, '')
      expect(s).not_to be_empty
      # The string is highly formatted with ANSI and box drawing chars, and
      # depending on padding, certain words may be truncated or spaced uniquely.
      # We just check for presence of some key semantic strings in the raw output.
      expect(s).to match(/EXECUTION/i)
      expect(s).to match(/FLOW/i)
      expect(s).to match(/B-SOL_USDT/)
      expect(s).to match(/LONG/i)
    end

    context 'when there are no working orders' do
      let(:snapshot) do
        CoindcxBot::Core::Engine::Snapshot.new(
          pairs: %w[B-SOL_USDT],
          ticks: { 'B-SOL_USDT' => { price: '150.0', at: Time.now } },
          positions: [],
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
          working_orders: [],
          ws_last_tick_ms_ago: 5,
          strategy_last_by_pair: {},
          regime: CoindcxBot::Regime::TuiState.disabled,
          smc_setup: CoindcxBot::SmcSetup::TuiOverlay::DISABLED,
          exchange_positions: [],
          exchange_positions_error: nil,
          exchange_positions_fetched_at: nil,
          live_tui_metrics: {}
        )
      end

      it 'renders without raising' do
        expect { panel.render }.not_to raise_error
      end
    end

  end
end
