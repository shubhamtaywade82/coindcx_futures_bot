# frozen_string_literal: true

require 'bigdecimal'

RSpec.describe CoindcxBot::Tui::Panels::HeaderPanel do
  let(:output) { StringIO.new }
  let(:broker_double) { double('broker', paper?: false, tui_working_orders: []) }
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
      recent_events: [],
      working_orders: [],
      ws_last_tick_ms_ago: 42
    )
  end
  let(:engine) { double('engine', snapshot: snapshot, broker: broker_double) }
  let(:panel) do
    described_class.new(engine: engine, origin_row: 0, output: output)
  end

  describe '#render' do
    it 'renders mode, ws, engine, pnl, and balance line' do
      panel.render
      rendered = output.string

      expect(rendered).to include('PAPER')
      expect(rendered).to include('MODE:')
      expect(rendered).to include('WS:')
      expect(rendered).to include('ENGINE: RUN')
      expect(rendered).to include('PnL:')
      expect(rendered).to include('123.45')
      expect(rendered).to include('BAL:')
      expect(rendered).to include('50000')
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
          ws_last_tick_ms_ago: nil
        )
      end

      it 'renders warning indicators' do
        panel.render
        rendered = output.string

        expect(rendered).to include('LIVE')
        expect(rendered).to include('PAUSED')
        expect(rendered).to include('KILL')
        expect(rendered).to include('STALE')
        expect(rendered).to include('connection lost')
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
          capital_inr: nil,
          recent_events: [],
          working_orders: [],
          ws_last_tick_ms_ago: 10
        )
      end

      it 'renders realized, unrealized, and fees on the balance row' do
        panel.render
        rendered = output.string

        expect(rendered).to include('REAL:')
        expect(rendered).to include('15.50')
        expect(rendered).to include('UNREAL:')
        expect(rendered).to include('FEES:')
      end
    end
  end

  describe '#row_count' do
    it 'returns 4' do
      expect(panel.row_count).to eq(4)
    end
  end
end
