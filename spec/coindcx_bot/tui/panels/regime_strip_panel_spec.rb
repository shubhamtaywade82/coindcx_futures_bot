# frozen_string_literal: true

RSpec.describe CoindcxBot::Tui::Panels::RegimeStripPanel do
  let(:output) { StringIO.new }
  let(:broker_double) { double('broker', paper?: false, tui_working_orders: []) }
  let(:config) do
    instance_double(CoindcxBot::Config, regime_enabled?: false)
  end
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
      regime: CoindcxBot::Regime::TuiState.build(config),
      smc_setup: CoindcxBot::SmcSetup::TuiOverlay::DISABLED,
      exchange_positions: [],
      exchange_positions_error: nil,
      exchange_positions_fetched_at: nil,
      live_tui_metrics: {}
    )
  end
  let(:engine) { double('engine', snapshot: snapshot, broker: broker_double, config: config) }
  let(:panel) { described_class.new(engine: engine, origin_row: 2, output: output) }

  before { allow(CoindcxBot::Tui::TermWidth).to receive(:columns).and_return(100) }

  describe '#render' do
    it 'uses one compact line when regime is disabled in the snapshot', :aggregate_failures do
      panel.render
      s = output.string
      expect(s).to include('REGIME')
      expect(s).to include('off')
      expect(s).to include('regime.enabled')
      expect(s).not_to include('Mdl:')
    end

    it 'shows STANDBY and n/a placeholders when regime is enabled in config' do
      allow(config).to receive(:regime_enabled?).and_return(true)
      allow(config).to receive(:regime_ai_enabled?).and_return(false)
      snap = CoindcxBot::Core::Engine::Snapshot.new(**snapshot.to_h.merge(regime: CoindcxBot::Regime::TuiState.build(config)))
      eng = double('engine', snapshot: snap, broker: broker_double, config: config)
      described_class.new(engine: eng, origin_row: 0, output: output).render
      expect(output.string).to include('STANDBY')
      expect(output.string).to include('Pn/a')
      expect(output.string).to include('PIPE:IDLE')
      expect(output.string).to include('awaiting HmmEngine')
      expect(output.string).to include('┌ REGIME ')
      expect(output.string).not_to include('┌ REGIME ·')
    end

    it 'shows the focused instrument in the regime box title when regime_pair is present' do
      allow(config).to receive(:regime_enabled?).and_return(true)
      allow(config).to receive(:regime_ai_enabled?).and_return(false)
      regime = CoindcxBot::Regime::TuiState::STANDBY.merge(
        active: true,
        regime_pair: 'B-SOL_USDT',
        label: 'S3',
        probability_pct: 62.0,
        stability_bars: 3,
        flicker_display: 'low',
        confirmed: false,
        vol_rank_display: '5/5',
        transition_display: 'tier_a',
        quant_display: 'S3 p=58%',
        hmm_display: '—',
        status: 'PIPE:HMM'
      )
      snap = CoindcxBot::Core::Engine::Snapshot.new(**snapshot.to_h.merge(regime: regime))
      eng = double('engine', snapshot: snap, broker: broker_double, config: config)
      described_class.new(engine: eng, origin_row: 0, output: output).render
      expect(output.string).to include('┌ REGIME · SOL ')
    end

    it 'adds wrapped detail lines for full AI transition and notes' do
      allow(config).to receive(:regime_enabled?).and_return(true)
      allow(config).to receive(:regime_ai_enabled?).and_return(true)
      long_notes = 'The HMM indicates a strong regime while spot holds the range for several sessions.'
      long_trans = 'State has remained consistent across the sampled bars without a vol spike.'
      regime = CoindcxBot::Regime::TuiState::STANDBY_AI.merge(
        active: true,
        label: 'S1',
        probability_pct: 99.0,
        stability_bars: 24,
        flicker_display: 'steady',
        confirmed: false,
        vol_rank_display: '3/4',
        transition_display: 'short',
        quant_display: 'S1 p=99%',
        hmm_display: 'AI: preview only',
        ai_transition_full: long_trans,
        ai_notes_full: long_notes,
        status: 'PIPE:RUN'
      )
      snap = CoindcxBot::Core::Engine::Snapshot.new(**snapshot.to_h.merge(regime: regime))
      eng = double('engine', snapshot: snap, broker: broker_double, config: config)
      panel = described_class.new(engine: eng, origin_row: 0, output: output)
      expect(panel.row_count).to be > 4
      panel.render
      expect(output.string).to include('A:↓')
      expect(output.string).to include('AI:↓')
      expect(output.string).to include('A· ')
      expect(output.string).to include('n· ')
      expect(output.string).to include(long_trans[0, 40])
      expect(output.string).to include(long_notes[0, 40])
    end
  end

  describe '#row_count' do
    it 'is one row when regime is disabled' do
      expect(panel.row_count).to eq(1)
    end

    it 'is four rows when regime is enabled in config' do
      allow(config).to receive(:regime_enabled?).and_return(true)
      allow(config).to receive(:regime_ai_enabled?).and_return(false)
      snap_on = CoindcxBot::Core::Engine::Snapshot.new(**snapshot.to_h.merge(regime: CoindcxBot::Regime::TuiState.build(config)))
      eng_on = double('engine', snapshot: snap_on, broker: broker_double, config: config)
      expect(described_class.new(engine: eng_on, origin_row: 0, output: output).row_count).to eq(4)
    end
  end
end
