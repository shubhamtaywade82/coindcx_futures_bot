# frozen_string_literal: true

RSpec.describe CoindcxBot::Tui::Panels::OrderflowPanel do
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
        ai_analysis: {
          enabled: true,
          status: 'OK',
          pair: 'B-SOL_USDT',
          side: 'LONG',
          confidence_pct: 68.2,
          entry_zone: { min: 92.9, max: 93.2 },
          stop_loss: 92.4,
          targets: [93.8, 94.2],
          levels_to_watch: [92.7, 93.5],
          rationale: 'Confluence supports continuation.',
          updated_at: Time.now
        }
      )
    )
  end

  subject(:panel) do
    described_class.new(
      bus: bus,
      engine: engine,
      origin_row: 0,
      focus_pair_proc: -> { 'B-SOL_USDT' },
      output: output
    )
  end

  it 'renders orderflow with ai analysis on the right' do
    panel.render
    text = output.string
    expect(text).to include('ORDERFLOW ENGINE')
    expect(text).to include('AI Analysis:')
    expect(text).to include('BIAS:')
    expect(text).to include('ENTRY:')
  end
end
