# frozen_string_literal: true

RSpec.describe CoindcxBot::Persistence::PaperStore do
  let(:db_path) { Tempfile.new(['paper_store', '.sqlite3']).path }
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
  end

  describe 'fills' do
    it 'inserts and retrieves fills for an order' do
      order_id = store.insert_order(pair: 'B-SOL_USDT', side: 'long', order_type: 'market', price: '100', quantity: '1')
      store.insert_fill(order_id: order_id, price: '100.05', quantity: '1', fee: '0.04', slippage: '0.05')

      fills = store.fills_for_order(order_id)
      expect(fills.size).to eq(1)
      expect(fills.first[:price]).to eq('100.05')
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
end
