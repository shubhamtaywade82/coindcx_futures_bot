# frozen_string_literal: true

require 'sqlite3'
require 'securerandom'

RSpec.describe CoindcxBot::Persistence::PaperStore do
  let(:db_path) { File.join(Dir.tmpdir, "coindcx_paper_store_#{SecureRandom.hex(12)}.sqlite3") }
  subject(:store) { described_class.new(db_path) }

  after do
    store.close
    File.delete(db_path) if File.exist?(db_path)
  end

  describe 'orders' do
    it 'inserts and retrieves an order' do
      id = store.insert_order(pair: 'B-SOL_USDT', side: 'long', order_type: 'market', price: '100', quantity: '1')
      order = store.find_order(id)

      expect(order[:pair]).to eq('B-SOL_USDT')
      expect(order[:side]).to eq('long')
      expect(order[:status]).to eq('new')
    end

    it 'updates order status' do
      id = store.insert_order(pair: 'B-SOL_USDT', side: 'long', order_type: 'market', price: '100', quantity: '1')
      store.update_order_status(id, 'filled')

      expect(store.find_order(id)[:status]).to eq('filled')
    end

    it 'queries orders by pair and status' do
      store.insert_order(pair: 'B-SOL_USDT', side: 'long', order_type: 'market', price: '100', quantity: '1', status: 'filled')
      store.insert_order(pair: 'B-ETH_USDT', side: 'short', order_type: 'market', price: '2000', quantity: '0.5', status: 'filled')

      sol_orders = store.orders_by_pair('B-SOL_USDT', status: 'filled')
      expect(sol_orders.size).to eq(1)
      expect(sol_orders.first[:pair]).to eq('B-SOL_USDT')
    end

    it 'returns working_orders for new, working, and accepted statuses' do
      store.insert_order(pair: 'B-SOL_USDT', side: 'long', order_type: 'market', price: '1', quantity: '1', status: 'filled')
      store.insert_order(pair: 'B-SOL_USDT', side: 'long', order_type: 'limit', price: '100', quantity: '1', status: 'working',
                         limit_price: '99')
      store.insert_order(pair: 'B-ETH_USDT', side: 'short', order_type: 'market', price: '2000', quantity: '0.1', status: 'accepted')

      rows = store.working_orders
      expect(rows.size).to eq(2)
      expect(rows.map { |r| r[:pair] }.uniq.sort).to eq(%w[B-ETH_USDT B-SOL_USDT])
    end

    it 'inserts optional bracket columns' do
      id = store.insert_order(
        pair: 'B-SOL_USDT', side: 'long', order_type: 'limit', price: '100', quantity: '1', status: 'new',
        limit_price: '98', stop_price: '90', group_id: 7, group_role: 'entry', metadata: { k: 1 }
      )
      row = store.find_order(id)
      expect(row[:limit_price]).to eq('98')
      expect(row[:stop_price]).to eq('90')
      expect(row[:group_id]).to eq(7)
      expect(row[:group_role]).to eq('entry')
      expect(JSON.parse(row[:metadata])['k']).to eq(1)
    end
  end

  describe 'fills' do
    it 'inserts and retrieves fills for an order' do
      order_id = store.insert_order(pair: 'B-SOL_USDT', side: 'long', order_type: 'market', price: '100', quantity: '1')
      store.insert_fill(order_id: order_id, price: '100.05', quantity: '1', fee: '0.04', slippage: '0.05')

      fills = store.fills_for_order(order_id)
      expect(fills.size).to eq(1)
      expect(fills.first[:price]).to eq('100.05')
      expect(fills.first[:trigger]).to eq('market_order')
    end

    it 'records fill trigger' do
      order_id = store.insert_order(pair: 'B-SOL_USDT', side: 'long', order_type: 'market', price: '100', quantity: '1')
      store.insert_fill(order_id: order_id, price: '100', quantity: '1', fee: '0', slippage: '0', trigger: 'limit')
      expect(store.fills_for_order(order_id).first[:trigger]).to eq('limit')
    end
  end

  describe 'positions' do
    it 'opens and closes a position with realized PnL' do
      id = store.insert_position(pair: 'B-SOL_USDT', side: 'long', quantity: BigDecimal('1'), entry_price: BigDecimal('100'))
      pos = store.find_position(id)

      expect(pos[:status]).to eq('open')
      expect(pos[:pair]).to eq('B-SOL_USDT')

      store.close_position(id, realized_pnl: BigDecimal('5.5'))
      closed = store.find_position(id)

      expect(closed[:status]).to eq('closed')
      expect(closed[:realized_pnl]).to eq('5.5')
    end

    it 'reduces position quantity and accumulates PnL' do
      id = store.insert_position(pair: 'B-SOL_USDT', side: 'long', quantity: BigDecimal('2'), entry_price: BigDecimal('100'))
      store.reduce_position(id, new_quantity: BigDecimal('1'), realized_pnl_delta: BigDecimal('3'))

      pos = store.find_position(id)
      expect(BigDecimal(pos[:quantity])).to eq(BigDecimal('1'))
      expect(BigDecimal(pos[:realized_pnl])).to eq(BigDecimal('3'))
    end

    it 'finds open position for a pair' do
      store.insert_position(pair: 'B-SOL_USDT', side: 'long', quantity: BigDecimal('1'), entry_price: BigDecimal('100'))
      pos = store.open_position_for('B-SOL_USDT')

      expect(pos).not_to be_nil
      expect(pos[:pair]).to eq('B-SOL_USDT')
    end

    it 'returns nil for closed positions' do
      id = store.insert_position(pair: 'B-SOL_USDT', side: 'long', quantity: BigDecimal('1'), entry_price: BigDecimal('100'))
      store.close_position(id, realized_pnl: BigDecimal('0'))

      expect(store.open_position_for('B-SOL_USDT')).to be_nil
    end
  end

  describe 'events' do
    it 'inserts and retrieves events' do
      store.insert_event(event_type: 'order_filled', payload: { pair: 'B-SOL_USDT' })
      events = store.recent_events(10)

      expect(events.size).to eq(1)
      expect(events.first[:event_type]).to eq('order_filled')
    end
  end

  describe 'aggregates' do
    it 'totals fees across all fills' do
      order_id = store.insert_order(pair: 'B-SOL_USDT', side: 'long', order_type: 'market', price: '100', quantity: '1')
      store.insert_fill(order_id: order_id, price: '100', quantity: '1', fee: '0.04', slippage: '0.05')
      store.insert_fill(order_id: order_id, price: '100', quantity: '1', fee: '0.06', slippage: '0.03')

      expect(store.total_fees).to eq(BigDecimal('0.1'))
      expect(store.total_slippage).to eq(BigDecimal('0.08'))
    end

    it 'totals realized PnL across closed positions' do
      id1 = store.insert_position(pair: 'B-SOL_USDT', side: 'long', quantity: BigDecimal('1'), entry_price: BigDecimal('100'))
      store.close_position(id1, realized_pnl: BigDecimal('10'))

      id2 = store.insert_position(pair: 'B-ETH_USDT', side: 'short', quantity: BigDecimal('1'), entry_price: BigDecimal('2000'))
      store.close_position(id2, realized_pnl: BigDecimal('-3'))

      expect(store.total_realized_pnl).to eq(BigDecimal('7'))
    end
  end

  describe 'restart recovery' do
    it 'persists positions across store instances' do
      store.insert_position(pair: 'B-SOL_USDT', side: 'long', quantity: BigDecimal('1'), entry_price: BigDecimal('100'))
      store.close

      recovered_store = described_class.new(db_path)
      positions = recovered_store.open_positions
      expect(positions.size).to eq(1)
      expect(positions.first[:pair]).to eq('B-SOL_USDT')
      recovered_store.close
    end
  end

  describe 'legacy sqlite upgrade' do
    it 'adds missing columns to an existing paper_orders table' do
      path = File.join(Dir.tmpdir, "coindcx_paper_legacy_#{SecureRandom.hex(12)}.sqlite3")
      raw = SQLite3::Database.new(path)
      raw.execute_batch(<<~SQL)
        CREATE TABLE paper_orders (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          pair TEXT NOT NULL,
          side TEXT NOT NULL,
          order_type TEXT NOT NULL,
          price TEXT NOT NULL,
          quantity TEXT NOT NULL,
          status TEXT NOT NULL DEFAULT 'new',
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL
        );
        CREATE TABLE paper_fills (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          order_id INTEGER NOT NULL,
          price TEXT NOT NULL,
          quantity TEXT NOT NULL,
          fee TEXT NOT NULL DEFAULT '0',
          slippage TEXT NOT NULL DEFAULT '0',
          created_at TEXT NOT NULL
        );
        CREATE TABLE paper_positions (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          pair TEXT NOT NULL,
          side TEXT NOT NULL,
          quantity TEXT NOT NULL,
          entry_price TEXT NOT NULL,
          realized_pnl TEXT NOT NULL DEFAULT '0',
          status TEXT NOT NULL DEFAULT 'open',
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL
        );
        CREATE TABLE paper_events (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          event_type TEXT NOT NULL,
          payload TEXT NOT NULL DEFAULT '{}',
          created_at TEXT NOT NULL
        );
        CREATE TABLE paper_account_snapshots (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          equity TEXT NOT NULL,
          realized_pnl TEXT NOT NULL,
          unrealized_pnl TEXT NOT NULL,
          total_fees TEXT NOT NULL DEFAULT '0',
          total_slippage TEXT NOT NULL DEFAULT '0',
          created_at TEXT NOT NULL
        );
      SQL
      raw.close

      upgraded = described_class.new(path)
      id = upgraded.insert_order(
        pair: 'B-SOL_USDT', side: 'long', order_type: 'limit', price: '100', quantity: '1', status: 'working',
        limit_price: '99'
      )
      expect(upgraded.find_order(id)[:limit_price]).to eq('99')
      oid = upgraded.insert_order(pair: 'B-SOL_USDT', side: 'long', order_type: 'market', price: '100', quantity: '1')
      upgraded.insert_fill(order_id: oid, price: '100', quantity: '1', fee: '0', slippage: '0')
      expect(upgraded.fills_for_order(oid).first[:trigger]).to eq('market_order')
      upgraded.close
      File.delete(path) if File.exist?(path)
    end
  end
end
