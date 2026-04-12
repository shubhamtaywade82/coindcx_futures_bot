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
      scalper_mode?: false
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
      smc_setup: CoindcxBot::SmcSetup::TuiOverlay::DISABLED
    )
  end
  let(:engine) { double('engine', snapshot: snapshot, broker: broker_double, config: config) }
  let(:panel) do
    described_class.new(engine: engine, origin_row: 0, output: output)
  end

  before do
    allow(engine).to receive(:ws_feed_stale?).and_return(false)
    allow(engine).to receive(:inr_per_usdt).and_return(BigDecimal('83'))
  end

  describe '#render' do
    it 'renders mode, ws, engine, net pnl, balance, and desk counts' do
      panel.render
      rendered = output.string

      expect(rendered).to include('PAPER')
      expect(rendered).not_to include('REGIME·')
      expect(rendered).to include('MODE:')
      expect(rendered).to include('WS:')
      expect(rendered).to include('ENGINE: RUN')
      expect(rendered).to include('NET:')
      expect(rendered).to include('123.45')
      expect(rendered).to include('BAL:')
      expect(rendered).to include('50000')
      expect(rendered).to include('POS:')
      expect(rendered).to include('ORD:')
      expect(rendered).to include('LAST EVT:')
    end

    it 'shows LAT after FEED on the first status line' do
      panel.render
      rendered = output.string
      expect(rendered.index('FEED:')).to be < rendered.index('LAT:')
    end

    it 'renders SCALP when config is in scalper mode' do
      allow(config).to receive(:scalper_mode?).and_return(true)
      panel.render
      expect(output.string).to include('SCALP')
    end

    it 'renders REGIME·ON when snapshot.regime.enabled and not yet active' do
      snap_on = CoindcxBot::Core::Engine::Snapshot.new(
        **snapshot.to_h.merge(regime: CoindcxBot::Regime::TuiState::STANDBY)
      )
      eng_on = double('engine', snapshot: snap_on, broker: broker_double, config: config)
      allow(eng_on).to receive(:inr_per_usdt).and_return(BigDecimal('83'))
      allow(eng_on).to receive(:ws_feed_stale?).and_return(false)
      described_class.new(engine: eng_on, origin_row: 0, output: output).render
      expect(output.string).to include('REGIME·ON')
    end

    it 'shows LEV from max_leverage when order_defaults omit leverage (nil.to_i is not 0)' do
      allow(config).to receive(:execution).and_return({ order_defaults: { margin_currency_short_name: 'USDT' } })
      allow(config).to receive(:risk).and_return({ max_daily_loss_inr: 1500, max_leverage: 10 })
      panel.render
      expect(output.string).to match(/LEV:.*10x/m)
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
          smc_setup: CoindcxBot::SmcSetup::TuiOverlay::DISABLED
        )
      end

      it 'renders warning indicators' do
        panel.render
        rendered = output.string

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
          smc_setup: CoindcxBot::SmcSetup::TuiOverlay::DISABLED
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
    it 'returns 4' do
      expect(panel.row_count).to eq(4)
    end
  end
end
