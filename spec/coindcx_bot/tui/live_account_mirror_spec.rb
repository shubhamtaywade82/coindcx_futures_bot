# frozen_string_literal: true

require 'bigdecimal'

RSpec.describe CoindcxBot::Tui::LiveAccountMirror do
  describe '.normalize_bot_pair' do
    it 'adds B- prefix for instrument-style codes' do
      expect(described_class.normalize_bot_pair({ 'instrument' => 'ETH_USDT' })).to eq('B-ETH_USDT')
    end

    it 'keeps B- pair spelling' do
      expect(described_class.normalize_bot_pair({ pair: 'B-SOL_USDT' })).to eq('B-SOL_USDT')
    end
  end

  describe '.pseudo_journal_from_exchange' do
    it 'maps active_pos sign to side and quantity' do
      row = { pair: 'B-XRP_USDT', active_pos: '-100.5', average_entry_price: '1.5', unrealized_pnl: '-2.25' }
      h = described_class.pseudo_journal_from_exchange(row.transform_keys(&:to_sym))
      expect(h[:side]).to eq('short')
      expect(h[:quantity]).to eq('100.5')
      expect(h[:exchange_unrealized_usdt]).to eq('-2.25')
    end

    it 'uses CoinDCX avg_price as entry' do
      row = { pair: 'B-SOL_USDT', active_pos: '-2', avg_price: '150.25' }
      h = described_class.pseudo_journal_from_exchange(row.transform_keys(&:to_sym))
      expect(h[:entry_price]).to eq('150.25')
    end
  end

  describe '.extract_wallet_usdt_balance' do
    it 'reads USDT balance from a wallets array envelope' do
      payload = { 'wallets' => [{ 'currency_short_name' => 'USDT', 'balance' => '123.45' }] }
      expect(described_class.extract_wallet_usdt_balance(payload)).to eq(BigDecimal('123.45'))
    end

    it 'reads USDT balance from a top-level JSON array (CoinDCX futures wallets response)' do
      payload = [{ 'currency_short_name' => 'USDT', 'balance' => '99.1' }]
      expect(described_class.extract_wallet_usdt_balance(payload)).to eq(BigDecimal('99.1'))
    end

    it 'returns nil when only an INR row exists' do
      payload = [{ 'currency_short_name' => 'INR', 'balance' => '50000' }]
      expect(described_class.extract_wallet_usdt_balance(payload)).to be_nil
    end

    it 'returns only the USDT row when INR and USDT rows are both present' do
      payload = [
        { 'currency_short_name' => 'INR', 'balance' => '50000' },
        { 'currency_short_name' => 'USDT', 'balance' => '12.34' }
      ]
      expect(described_class.extract_wallet_usdt_balance(payload)).to eq(BigDecimal('12.34'))
    end
  end

  describe '.extract_wallet_balance_for_display' do
    let(:both) do
      [
        { 'currency_short_name' => 'USDT', 'balance' => '18.56' },
        { 'currency_short_name' => 'INR', 'balance' => '1541.08' }
      ]
    end

    it 'selects the INR row when margin currency is INR' do
      h = described_class.extract_wallet_balance_for_display(both, 'INR')
      expect(h[:currency]).to eq('INR')
      expect(h[:amount]).to eq(BigDecimal('1541.08'))
    end

    it 'selects the USDT row when margin currency is USDT' do
      h = described_class.extract_wallet_balance_for_display(both, 'USDT')
      expect(h[:currency]).to eq('USDT')
      expect(h[:amount]).to eq(BigDecimal('18.56'))
    end
  end

  describe '.extract_wallet_snapshot_for_display' do
    it 'parses locked and cross margins on the margin-currency row' do
      row = {
        currency_short_name: 'INR',
        balance: '1000',
        locked_balance: '50',
        cross_order_margin: '10',
        cross_user_margin: '20'
      }
      snap = described_class.extract_wallet_snapshot_for_display([row], 'INR')
      expect(snap[:currency]).to eq('INR')
      expect(snap[:balance]).to eq(BigDecimal('1000'))
      expect(snap[:locked_balance]).to eq(BigDecimal('50'))
      expect(snap[:cross_order_margin]).to eq(BigDecimal('10'))
      expect(snap[:cross_user_margin]).to eq(BigDecimal('20'))
    end
  end

  describe '.combined_daily_pnl_inr_for_header' do
    let(:snap_class) { CoindcxBot::Core::Engine::Snapshot }

    it 'uses exchange REAL+UNREAL USDT at FX when realized_usdt is present (ignores journal)' do
      snap = snap_class.new(
        pairs: %w[B-SOL_USDT],
        ticks: {},
        positions: [],
        paused: false,
        kill_switch: false,
        stale: false,
        last_error: nil,
        daily_pnl: BigDecimal('-10_000'),
        running: true,
        dry_run: false,
        stale_tick_seconds: 45,
        paper_metrics: {},
        capital_inr: BigDecimal('50_000'),
        recent_events: [],
        working_orders: [],
        ws_last_tick_ms_ago: 5,
        strategy_last_by_pair: {},
        regime: CoindcxBot::Regime::TuiState.disabled,
        smc_setup: CoindcxBot::SmcSetup::TuiOverlay::DISABLED,
        exchange_positions: [],
        exchange_positions_error: nil,
        exchange_positions_fetched_at: nil,
        live_tui_metrics: { realized_usdt: BigDecimal('5'), unrealized_usdt: BigDecimal('-2') }
      )
      combined = described_class.combined_daily_pnl_inr_for_header(snap, BigDecimal('83'))
      expect(combined).to eq(BigDecimal('249')) # (5 + (-2)) * 83
    end

    it 'falls back to journal plus unreal when realized_usdt is omitted (legacy snapshots)' do
      snap = snap_class.new(
        pairs: %w[B-SOL_USDT],
        ticks: {},
        positions: [],
        paused: false,
        kill_switch: false,
        stale: false,
        last_error: nil,
        daily_pnl: BigDecimal('-10_000'),
        running: true,
        dry_run: false,
        stale_tick_seconds: 45,
        paper_metrics: {},
        capital_inr: BigDecimal('50_000'),
        recent_events: [],
        working_orders: [],
        ws_last_tick_ms_ago: 5,
        strategy_last_by_pair: {},
        regime: CoindcxBot::Regime::TuiState.disabled,
        smc_setup: CoindcxBot::SmcSetup::TuiOverlay::DISABLED,
        exchange_positions: [],
        exchange_positions_error: nil,
        exchange_positions_fetched_at: nil,
        live_tui_metrics: { unrealized_usdt: BigDecimal('-2') }
      )
      combined = described_class.combined_daily_pnl_inr_for_header(snap, BigDecimal('83'))
      expect(combined).to eq(BigDecimal('-10_166'))
    end

    it 'returns journal daily only when dry_run' do
      snap = snap_class.new(
        pairs: %w[B-SOL_USDT],
        ticks: {},
        positions: [],
        paused: false,
        kill_switch: false,
        stale: false,
        last_error: nil,
        daily_pnl: BigDecimal('-100'),
        running: true,
        dry_run: true,
        stale_tick_seconds: 45,
        paper_metrics: {},
        capital_inr: BigDecimal('50_000'),
        recent_events: [],
        working_orders: [],
        ws_last_tick_ms_ago: 5,
        strategy_last_by_pair: {},
        regime: CoindcxBot::Regime::TuiState.disabled,
        smc_setup: CoindcxBot::SmcSetup::TuiOverlay::DISABLED,
        exchange_positions: [],
        exchange_positions_error: nil,
        exchange_positions_fetched_at: nil,
        live_tui_metrics: { unrealized_usdt: BigDecimal('-99') }
      )
      expect(described_class.combined_daily_pnl_inr_for_header(snap, BigDecimal('83'))).to eq(BigDecimal('-100'))
    end
  end

  describe '.sum_realized_usdt' do
    it 'sums realized fields on open rows only' do
      rows = [
        { pair: 'B-SOL_USDT', active_pos: '-1', realized_pnl_session: '12.5' },
        { pair: 'B-ETH_USDT', active_pos: '0', realized_pnl_session: '99' }
      ]
      expect(described_class.sum_realized_usdt(rows)).to eq(BigDecimal('12.5'))
    end
  end

  describe '.sum_unrealized_usdt' do
    it 'marks to market when pnl is absent but avg_price and LTP exist' do
      rows = [
        { pair: 'B-ETH_USDT', active_pos: '-1', avg_price: '3000', mark_price: '3100' }
      ]
      ticks = { 'B-ETH_USDT' => { price: BigDecimal('3100') } }
      expect(described_class.sum_unrealized_usdt(rows, ticks)).to eq(BigDecimal('-100'))
    end
  end
end
