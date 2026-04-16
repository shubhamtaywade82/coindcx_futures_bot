# frozen_string_literal: true

RSpec.describe CoindcxBot::Tui::Panels::SmcSetupStripPanel do
  let(:output) { StringIO.new }
  let(:broker_double) { double('broker', paper?: false, tui_working_orders: []) }
  let(:config) do
    instance_double(CoindcxBot::Config, pairs: %w[B-SOL_USDT], scalper_mode?: false)
  end

  def snap(smc)
    CoindcxBot::Core::Engine::Snapshot.new(
      pairs: %w[B-SOL_USDT],
      ticks: {},
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
      smc_setup: smc,
      exchange_positions: [],
      exchange_positions_error: nil,
      exchange_positions_fetched_at: nil,
      live_tui_metrics: {}
    )
  end

  it 'renders one line when smc_setup is disabled' do
    engine = double('engine', snapshot: snap(CoindcxBot::SmcSetup::TuiOverlay::DISABLED), config: config, broker: broker_double)
    described_class.new(engine: engine, origin_row: 0, output: output).render
    expect(output.string).to include('SMC·SETUP')
    expect(output.string).to include('off')
    expect(described_class.new(engine: engine, origin_row: 0, output: output).row_count).to eq(1)
  end

  it 'renders planner line and active setups when enabled' do
    smc = {
      enabled: true,
      planner_enabled: true,
      gatekeeper_enabled: false,
      auto_execute: false,
      planner_last_at: Time.now - 30,
      planner_error: '',
      planner_interval_s: 120,
      active_count: 1,
      active_setups: [
        { setup_id: 'p1', pair: 'B-SOL_USDT', state: 'pending_sweep', direction: 'long', gatekeeper: false }
      ]
    }
    engine = double('engine', snapshot: snap(smc), config: config, broker: broker_double)
    p = described_class.new(engine: engine, origin_row: 0, output: output)
    expect(p.row_count).to eq(2)
    p.render
    s = output.string
    expect(s).to include('PLANNER')
    expect(s).to include('ACTIVE')
    expect(s).to include('p1')
    expect(s).to include('SOL_USDT')
    expect(s).to include('P_SW')
  end

  it 'abbreviates awaiting_confirmations and shortens UUID setup ids on the ACTIVE line' do
    uuid = 'e3f9b2c4-7a1b-4c2d-9e8f-1234567890ab'
    smc = {
      enabled: true,
      planner_enabled: false,
      gatekeeper_enabled: false,
      auto_execute: false,
      planner_last_at: nil,
      planner_error: '',
      planner_interval_s: 120,
      active_count: 2,
      active_setups: [
        { setup_id: 'sol_202604_slice_flow', pair: 'B-SOL_USDT', state: 'awaiting_confirmations', direction: 'long',
          gatekeeper: false },
        { setup_id: uuid, pair: 'B-ETH_USDT', state: 'awaiting_confirmations', direction: 'long', gatekeeper: false }
      ]
    }
    engine = double('engine', snapshot: snap(smc), config: config, broker: broker_double)
    described_class.new(engine: engine, origin_row: 0, output: output).render
    s = output.string
    expect(s).to include('AW_CF')
    expect(s).to include('e3f9b2c4')
    expect(s).not_to include('awaiting_confirmations')
    expect(s).to include('sol_202604_slice_flow')
  end
end
