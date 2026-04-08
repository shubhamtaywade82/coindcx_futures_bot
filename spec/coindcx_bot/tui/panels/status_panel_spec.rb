# frozen_string_literal: true

require 'bigdecimal'

RSpec.describe CoindcxBot::Tui::Panels::StatusPanel do
  let(:output) { StringIO.new }
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
      stale_tick_seconds: 45
    )
  end
  let(:engine) { double('engine', snapshot: snapshot) }
  let(:panel) do
    described_class.new(engine: engine, origin_row: 0, output: output)
  end

  describe '#render' do
    it 'renders mode, status, positions, and metrics lines' do
      panel.render
      rendered = output.string

      expect(rendered).to include('DRY RUN')
      expect(rendered).to include('Engine')
      expect(rendered).to include('Positions')
      expect(rendered).to include('none open')
      expect(rendered).to include('PnL today')
      expect(rendered).to include('123.45')
    end

    context 'with open positions' do
      let(:snapshot) do
        CoindcxBot::Core::Engine::Snapshot.new(
          pairs: %w[B-SOL_USDT],
          ticks: {},
          positions: [
            { id: 4, pair: 'B-SOL_USDT', side: 'long', quantity: '0.02', entry_price: '142.5' }
          ],
          paused: false,
          kill_switch: false,
          stale: false,
          last_error: nil,
          daily_pnl: BigDecimal('0'),
          running: true,
          dry_run: true,
          stale_tick_seconds: 45
        )
      end

      it 'renders id, pair, side, qty, entry' do
        panel.render
        rendered = output.string
        expect(rendered).to include('#4')
        expect(rendered).to include('B-SOL_USDT')
        expect(rendered).to include('long')
        expect(rendered).to include('0.02')
        expect(rendered).to include('142.5')
      end
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
          stale_tick_seconds: 45
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

      expect(output.string.scan('DRY RUN').size).to eq(3)
    end
  end

  describe '#row_count' do
    it 'returns 4' do
      expect(panel.row_count).to eq(4)
    end
  end
end
