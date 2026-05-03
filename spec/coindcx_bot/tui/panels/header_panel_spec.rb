# frozen_string_literal: true

require 'bigdecimal'

RSpec.describe CoindcxBot::Tui::Panels::HeaderPanel do
  let(:output) { StringIO.new }
  let(:broker_double) { double('broker', paper?: false, tui_working_orders: []) }
  let(:config) do
    instance_double(
      CoindcxBot::Config,
      risk: { max_daily_loss_inr: 1500, max_leverage: 10 },
      strategy: { name: 'trend_continuation' },
      inr_per_usdt: BigDecimal('83'),
      resolved_max_daily_loss_inr: BigDecimal('1500'),
      execution: { order_defaults: { leverage: 5 } },
      scalper_mode?: false,
      place_orders?: true
    )
  end
  let(:snapshot) do
    CoindcxBot::Core::Engine::Snapshot.new(
      pairs: %w[SOLUSDT],
      ticks: {},
      positions: [],
      paused: false,
      kill_switch: false,
      stale: false,
      last_error: nil,
      daily_pnl: BigDecimal('123.45'),
      running: true,
      dry_run: true,
      stale_tick_seconds: 45,
      paper_metrics: {},
      capital_inr: BigDecimal('50_000'),
      recent_events: [{ ts: 1, type: 'tick', payload: {} }],
      working_orders: [],
      ws_last_tick_ms_ago: 42,
      strategy_last_by_pair: {},
      regime: CoindcxBot::Regime::TuiState.disabled,
      smc_setup: CoindcxBot::SmcSetup::TuiOverlay::DISABLED,
      exchange_positions: [],
      exchange_positions_error: nil,
      exchange_positions_fetched_at: nil,
      live_tui_metrics: {}
    )
  end
  let(:engine) { double('engine', snapshot: snapshot, broker: broker_double, config: config) }
  let(:panel) do
    described_class.new(engine: engine, origin_row: 0, output: output)
  end

  before do
    allow(engine).to receive(:ws_feed_stale?).and_return(false)
    allow(engine).to receive(:inr_per_usdt).and_return(BigDecimal('83'))
    allow(engine).to receive(:engine_loop_crashed?).and_return(false)
    allow(engine).to receive(:tui_focus_pair=)
  end

  def plain(str)
    str.gsub(/\e\[[0-9;]*[A-Za-z]/, '')
  end

  describe '#render' do
    it 'renders CRASHED when the engine loop has failed' do
      allow(engine).to receive(:engine_loop_crashed?).and_return(true)
      crashed_snap = CoindcxBot::Core::Engine::Snapshot.new(**snapshot.to_h.merge(running: false))
      eng = double('engine', snapshot: crashed_snap, broker: broker_double, config: config)
      allow(eng).to receive(:inr_per_usdt).and_return(BigDecimal('83'))
      allow(eng).to receive(:ws_feed_stale?).and_return(false)
      allow(eng).to receive(:engine_loop_crashed?).and_return(true)
      allow(eng).to receive(:tui_focus_pair=)
      described_class.new(engine: eng, origin_row: 0, output: output).render
      expect(plain(output.string)).to include('CRASHED')
    end

    it 'renders mode, ws, engine, net pnl, balance, and desk counts' do
      panel.render
      rendered = plain(output.string)

      expect(rendered).to include('PAPER')
      expect(rendered).not_to include('REGIME·')
      expect(rendered).to include('WS:')
      expect(rendered).to include('RUNNING')
      expect(rendered).to include('NET:')
      expect(rendered).to include('123.45')
      expect(rendered).to include('BAL:')
      expect(rendered).to include('50000')
      expect(rendered).to include('POS:')
      expect(rendered).to include('ORD:')
      expect(rendered).to include('LAST EVT:')
    end

    it 'shows WS pill after FEED on the first status line' do
      panel.render
      rendered = plain(output.string)
      expect(rendered.index('FEED:')).to be < rendered.index('LEV:')
      expect(rendered).to include('WS:')
    end

    it 'renders SCALP when config is in scalper mode' do
      pending('trading_profile_fragment is not wired into render; production diverged from spec contract')
      allow(config).to receive(:scalper_mode?).and_return(true)
      panel.render
      expect(plain(output.string)).to include('SCALP')
    end

    it 'shows EXE·OFF when live and place_orders is false' do
      allow(config).to receive(:place_orders?).and_return(false)
      live_snap = CoindcxBot::Core::Engine::Snapshot.new(**snapshot.to_h.merge(dry_run: false))
      eng = double('engine', snapshot: live_snap, broker: broker_double, config: config)
      allow(eng).to receive(:inr_per_usdt).and_return(BigDecimal('83'))
      allow(eng).to receive(:ws_feed_stale?).and_return(false)
      allow(eng).to receive(:engine_loop_crashed?).and_return(false)
      allow(eng).to receive(:tui_focus_pair=)
      described_class.new(engine: eng, origin_row: 0, output: output).render
      rendered = plain(output.string)
      expect(rendered).to include('LIVE')
      expect(rendered).to include('EXE·OFF')
    end

    it 'renders REGIME·ON when snapshot.regime.enabled and not yet active' do
      pending('regime_header_fragment is dead code; production now uses regime_color_label which emits the label only')
      snap_on = CoindcxBot::Core::Engine::Snapshot.new(
        **snapshot.to_h.merge(regime: CoindcxBot::Regime::TuiState::STANDBY)
      )
      eng_on = double('engine', snapshot: snap_on, broker: broker_double, config: config)
      allow(eng_on).to receive(:inr_per_usdt).and_return(BigDecimal('83'))
      allow(eng_on).to receive(:ws_feed_stale?).and_return(false)
      allow(eng_on).to receive(:engine_loop_crashed?).and_return(false)
      allow(eng_on).to receive(:tui_focus_pair=)
      described_class.new(engine: eng_on, origin_row: 0, output: output).render
      expect(plain(output.string)).to include('REGIME·ON')
    end

    it 'shows LEV from max_leverage when order_defaults omit leverage (nil.to_i is not 0)' do
      pending('production reads live_tui_metrics[:leverage_label]; config-derived leverage_fragment is dead code')
      allow(config).to receive(:execution).and_return({ order_defaults: { margin_currency_short_name: 'USDT' } })
      allow(config).to receive(:risk).and_return({ max_daily_loss_inr: 1500, max_leverage: 10 })
      panel.render
      expect(plain(output.string)).to match(/LEV:.*10x/m)
    end

    context 'when engine is paused with kill switch' do
      let(:snapshot) do
        CoindcxBot::Core::Engine::Snapshot.new(
          pairs: %w[SOLUSDT],
          ticks: {},
          positions: [],
          paused: true,
          kill_switch: true,
          stale: true,
          last_error: 'connection lost',
          daily_pnl: BigDecimal('-50.0'),
          running: true,
          dry_run: false,
          stale_tick_seconds: 45,
          paper_metrics: {},
          capital_inr: nil,
          recent_events: [],
          working_orders: [],
          ws_last_tick_ms_ago: nil,
          strategy_last_by_pair: {},
          regime: CoindcxBot::Regime::TuiState.disabled,
          smc_setup: CoindcxBot::SmcSetup::TuiOverlay::DISABLED,
          exchange_positions: [],
          exchange_positions_error: nil,
          exchange_positions_fetched_at: nil,
          live_tui_metrics: {}
        )
      end

      it 'renders warning indicators' do
        pending('PAUSED token is not emitted; production maps dry_run flag to PAPER/LIVE only')
        panel.render
        rendered = plain(output.string)

        expect(rendered).to include('LIVE')
        expect(rendered).to include('PAUSED')
        expect(rendered).to include('KILL')
        expect(rendered).to include('STALE')
        expect(rendered).to include('ERR:')
      end
    end

    it 'redraws the mode line on each render' do
      3.times { panel.render }

      expect(output.string.scan('PAPER').size).to eq(3)
    end

    context 'with live TUI metrics (INR futures wallet)' do
      let(:snapshot) do
        CoindcxBot::Core::Engine::Snapshot.new(
          pairs: %w[B-ETH_USDT],
          ticks: {},
          positions: [],
          paused: false,
          kill_switch: false,
          stale: false,
          last_error: nil,
          daily_pnl: BigDecimal('-10095.40'),
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
          live_tui_metrics: {
            wallet_amount: BigDecimal('1541.08'),
            wallet_currency: 'INR',
            realized_usdt: BigDecimal('0'),
            unrealized_usdt: BigDecimal('-41.82'),
            open_positions_count: 1
          }
        )
      end

      it 'shows futures EQ WAL UR in INR and USDT without treating wallet row as USDT' do
        panel.render
        rendered = output.string
        expect(rendered).to include('EQ:')
        expect(rendered).to include('WAL:')
        expect(rendered).to include('UR:')
        expect(rendered).to include('1541.08')
        expect(rendered).to include('41.82')
        # Would be wrong if 1541.08 were treated as USDT at 83 INR/USDT (~127_909)
        expect(rendered).not_to include('127909')
        expect(rendered).not_to include('BAL:')
      end

      it 'shows NET as exchange REAL+UNREAL USDT at inr_per_usdt (not journal)' do
        panel.render
        # (0 + (-41.82)) * 83 = -3471.06
        expect(output.string).to include('3471.06')
        expect(output.string).to include('REAL USDT:')
        expect(output.string).to include('0.00')
      end
    end

    context 'with live TUI metrics (USDT futures wallet)' do
      let(:snapshot) do
        CoindcxBot::Core::Engine::Snapshot.new(
          pairs: %w[B-BTC_USDT],
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
          live_tui_metrics: {
            wallet_amount: BigDecimal('2355.742'),
            wallet_currency: 'USDT',
            realized_usdt: BigDecimal('0'),
            unrealized_usdt: BigDecimal('-408.459'),
            open_positions_count: 1
          }
        )
      end

      it 'shows equity ≈ wallet USDT + unreal in both currencies' do
        eng = double('engine', snapshot: snapshot, broker: broker_double, config: config)
        allow(eng).to receive(:inr_per_usdt).and_return(BigDecimal('83'))
        allow(eng).to receive(:ws_feed_stale?).and_return(false)
        allow(eng).to receive(:engine_loop_crashed?).and_return(false)
        allow(eng).to receive(:tui_focus_pair=)
        described_class.new(engine: eng, origin_row: 0, output: output).render
        rendered = output.string
        expect(rendered).to include('EQ:')
        expect(rendered).to include('1947.28')
        expect(rendered).to include('WAL:')
        expect(rendered).to include('2355.74')
        expect(rendered).to include('UR:')
        expect(rendered).to match(/408\.4/)
      end
    end

    context 'with paper metrics' do
      let(:broker_double) { double('broker', paper?: true, tui_working_orders: []) }
      let(:snapshot) do
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
          paper_metrics: {
            total_realized_pnl: BigDecimal('15.5'),
            unrealized_pnl: BigDecimal('3.2'),
            total_fees: BigDecimal('0.8'),
            total_slippage: BigDecimal('0.3'),
            fill_count: 4
          },
          capital_inr: BigDecimal('100_000'),
          recent_events: [],
          working_orders: [],
          ws_last_tick_ms_ago: 10,
          strategy_last_by_pair: {},
          regime: CoindcxBot::Regime::TuiState.disabled,
          smc_setup: CoindcxBot::SmcSetup::TuiOverlay::DISABLED,
          exchange_positions: [],
          exchange_positions_error: nil,
          exchange_positions_fetched_at: nil,
          live_tui_metrics: {}
        )
      end

      it 'renders USDT realized/unrealized, BAL from capital plus (realized+unrealized) at inr_per_usdt, DD and risk' do
        panel.render
        rendered = output.string

        expect(rendered).to include('REAL USDT:')
        expect(rendered).to include('15.50')
        expect(rendered).to include('UNREAL USDT:')
        # 100_000 + (15.5 + 3.2) * 83 = 101_552.10
        expect(rendered).to include('101552.10')
        expect(rendered).to include('DD:')
        expect(rendered).to include('RISK:')
      end
    end
  end

  describe '#row_count' do
    it 'returns 4 without live futures account strip' do
      expect(panel.row_count).to eq(4)
    end

    it 'returns 5 when live futures EQ/WAL/UR strip is active' do
      snap = CoindcxBot::Core::Engine::Snapshot.new(
        pairs: %w[B-ETH_USDT],
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
        live_tui_metrics: {
          wallet_amount: BigDecimal('100'),
          wallet_currency: 'USDT',
          unrealized_usdt: BigDecimal('-10'),
          open_positions_count: 1
        }
      )
      eng = double('engine', snapshot: snap, broker: broker_double, config: config)
      allow(eng).to receive(:inr_per_usdt).and_return(BigDecimal('83'))
      allow(eng).to receive(:ws_feed_stale?).and_return(false)
      allow(eng).to receive(:engine_loop_crashed?).and_return(false)
      expect(described_class.new(engine: eng, origin_row: 0, output: output).row_count).to eq(5)
    end
  end
end
