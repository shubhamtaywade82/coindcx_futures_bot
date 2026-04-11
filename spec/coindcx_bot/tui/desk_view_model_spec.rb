# frozen_string_literal: true

require 'bigdecimal'

RSpec.describe CoindcxBot::Tui::DeskViewModel do
  let(:config) do
    instance_double(
      CoindcxBot::Config,
      risk: { max_daily_loss_inr: 1_500, max_leverage: 10 },
      strategy: { name: 'supertrend_profit' },
      resolved_max_daily_loss_inr: BigDecimal('1500'),
      execution: { order_defaults: { leverage: 5 } },
      trading_mode_label: 'SWING',
      scalper_mode?: false
    )
  end

  let(:snapshot) do
    CoindcxBot::Core::Engine::Snapshot.new(
      pairs: %w[B-SOL_USDT],
      ticks: { 'B-SOL_USDT' => { price: '150.0', at: Time.now } },
      positions: [
        { pair: 'B-SOL_USDT', side: 'long', quantity: '0.1', entry_price: '140.0', stop_price: '135.0' }
      ],
      paused: false,
      kill_switch: false,
      stale: false,
      last_error: nil,
      daily_pnl: BigDecimal('-112'),
      running: true,
      dry_run: true,
      stale_tick_seconds: 45,
      paper_metrics: { total_slippage: BigDecimal('0.05') },
      capital_inr: BigDecimal('50_000'),
      recent_events: [{ ts: 1, type: 'order_filled', payload: {} }],
      working_orders: [
        { id: 1, pair: 'B-SOL_USDT', side: 'sell', order_type: 'limit_order', quantity: '0.1',
          limit_price: '160', stop_price: nil }
      ],
      ws_last_tick_ms_ago: 12,
      strategy_last_by_pair: { 'B-SOL_USDT' => { action: :hold, reason: 'below_take_profit' } },
      regime: CoindcxBot::Regime::TuiState.disabled
    )
  end

  let(:tick_ticks) do
    {
      'B-SOL_USDT' => CoindcxBot::Tui::TickStore::Tick.new(
        symbol: 'B-SOL_USDT',
        ltp: 150.0,
        change_pct: 1.2,
        updated_at: Time.now,
        bid: 149.9,
        ask: 150.1,
        mark: nil
      )
    }
  end

  let(:vm) do
    described_class.new(
      snapshot: snapshot,
      tick_ticks: tick_ticks,
      symbols: %w[B-SOL_USDT],
      ws_stale_fn: ->(_s) { false },
      config: config
    )
  end

  describe '#execution_rows' do
    it 'returns a matrix row with side, qty, entry, ltp, and pnl label' do
      row = vm.execution_rows.first
      expect(row[:side]).to eq('LONG')
      expect(row[:qty]).to eq('0.1')
      expect(row[:entry]).to eq('140.00')
      expect(row[:ltp]).to eq('150.00')
      expect(row[:pnl_label]).to include('+1.00')
    end

    it 'marks flat symbols without a position' do
      flat_snap = CoindcxBot::Core::Engine::Snapshot.new(**snapshot.to_h.merge(positions: []))
      vm2 = described_class.new(
        snapshot: flat_snap,
        tick_ticks: tick_ticks,
        symbols: %w[B-SOL_USDT],
        ws_stale_fn: ->(_) { false },
        config: config
      )
      expect(vm2.execution_rows.first[:side]).to eq('FLAT')
    end

    it 'uses mark price for uPnL when the tick store carries mark' do
      ticks = {
        'B-SOL_USDT' => CoindcxBot::Tui::TickStore::Tick.new(
          symbol: 'B-SOL_USDT',
          ltp: 150.0,
          change_pct: 1.2,
          updated_at: Time.now,
          bid: 149.9,
          ask: 150.1,
          mark: 160.0
        )
      }
      vm2 = described_class.new(
        snapshot: snapshot,
        tick_ticks: ticks,
        symbols: %w[B-SOL_USDT],
        ws_stale_fn: ->(_) { false },
        config: config
      )
      row = vm2.execution_rows.first
      expect(row[:mark]).to eq('160.00')
      expect(row[:pnl_label]).to include('+2.00')
    end

    it 'surfaces journal stop price in the SL column' do
      expect(vm.execution_rows.first[:sl]).to eq('135.00')
    end
  end

  describe '#configured_leverage_label' do
    it 'returns the effective leverage cap from config' do
      expect(vm.configured_leverage_label).to eq('5x')
    end

    it 'uses max_leverage when order_defaults omit leverage' do
      cfg2 = instance_double(
        CoindcxBot::Config,
        risk: { max_daily_loss_inr: 1_500, max_leverage: 10 },
        strategy: { name: 'supertrend_profit' },
        resolved_max_daily_loss_inr: BigDecimal('1500'),
        execution: { order_defaults: { margin_currency_short_name: 'USDT' } },
        trading_mode_label: 'SWING',
        scalper_mode?: false
      )
      vm2 = described_class.new(
        snapshot: snapshot,
        tick_ticks: tick_ticks,
        symbols: %w[B-SOL_USDT],
        ws_stale_fn: ->(_) { false },
        config: cfg2
      )
      expect(vm2.configured_leverage_label).to eq('10x')
    end
  end

  describe '#grid_sidebar_lines' do
    it 'returns three sidebar lines for the futures grid' do
      lines = vm.grid_sidebar_lines
      expect(lines.size).to eq(3)
      expect(lines[0]).to include('DD')
      expect(lines[0]).to include('SWING')
      expect(lines[1]).to include('OPEN')
    end
  end

  describe '#order_flow_rows' do
    it 'abbreviates order types for the flow panel' do
      row = vm.order_flow_rows.first
      expect(row[:type_abbr]).to eq('LIM')
      expect(row[:status]).to eq('ACTIVE')
      expect(row[:latency]).to be_nil
    end

    it 'exposes working age in ms from placed_at when present' do
      t0 = Time.utc(2025, 6, 1, 12, 0, 0)
      allow(Time).to receive(:now).and_return(t0 + 1.5)
      snap2 = CoindcxBot::Core::Engine::Snapshot.new(
        **snapshot.to_h.merge(
          working_orders: [
            snapshot.working_orders.first.merge(placed_at: t0.utc.iso8601(3))
          ]
        )
      )
      vm2 = described_class.new(
        snapshot: snap2,
        tick_ticks: tick_ticks,
        symbols: %w[B-SOL_USDT],
        ws_stale_fn: ->(_) { false },
        config: config
      )
      expect(vm2.order_flow_rows.first[:latency]).to eq(1500)
    end
  end

  describe '#depth_rows' do
    it 'computes spread when bid and ask exist on the tick store' do
      rows = vm.depth_rows(now: Time.now)
      expect(rows.first[:bid]).to eq('149.90')
      expect(rows.first[:ask]).to eq('150.10')
      expect(rows.first[:spread]).to eq('0.20')
    end
  end

  describe '#risk_band and #loss_utilization_pct' do
    it 'returns HIGH when loss approaches the configured daily cap' do
      heavy = CoindcxBot::Core::Engine::Snapshot.new(**snapshot.to_h.merge(daily_pnl: BigDecimal('-1300')))
      vm2 = described_class.new(
        snapshot: heavy,
        tick_ticks: {},
        symbols: [],
        ws_stale_fn: ->(_) { false },
        config: config
      )
      expect(vm2.loss_utilization_pct).to eq(86.7)
      expect(vm2.risk_band).to eq('HIGH')
    end

    it 'returns CRIT when the kill switch is on' do
      k = CoindcxBot::Core::Engine::Snapshot.new(**snapshot.to_h.merge(kill_switch: true))
      vm2 = described_class.new(
        snapshot: k,
        tick_ticks: {},
        symbols: [],
        ws_stale_fn: ->(_) { false },
        config: config
      )
      expect(vm2.risk_band).to eq('CRIT')
    end
  end

  describe '#last_event_type' do
    it 'returns the newest journal event type' do
      expect(vm.last_event_type).to eq('ORDER_FILLED')
    end
  end

  describe '#strategy_name' do
    it 'returns the configured strategy name uppercased' do
      expect(vm.strategy_name).to eq('SUPERTREND_PROFIT')
    end
  end

  describe '#strategy_position_state' do
    it 'summarizes a single open position' do
      expect(vm.strategy_position_state).to eq('LONG SOL')
    end

    it 'returns FLAT when there are no positions' do
      flat = CoindcxBot::Core::Engine::Snapshot.new(**snapshot.to_h.merge(positions: []))
      vm2 = described_class.new(
        snapshot: flat,
        tick_ticks: tick_ticks,
        symbols: %w[B-SOL_USDT],
        ws_stale_fn: ->(_) { false },
        config: config
      )
      expect(vm2.strategy_position_state).to eq('FLAT')
    end
  end

  describe '#strategy_signal_summary' do
    it 'shows per-pair hold reasons from the last engine cycle' do
      expect(vm.strategy_signal_summary).to eq('SOL:below_take_profit')
    end

    it 'returns em dash when the kill switch is on' do
      k = CoindcxBot::Core::Engine::Snapshot.new(**snapshot.to_h.merge(kill_switch: true))
      vm2 = described_class.new(
        snapshot: k,
        tick_ticks: {},
        symbols: %w[B-SOL_USDT],
        ws_stale_fn: ->(_) { false },
        config: config
      )
      expect(vm2.strategy_signal_summary).to eq('—')
    end
  end
end
