# frozen_string_literal: true

require 'securerandom'

RSpec.describe CoindcxBot::Execution::PaperBroker do
  let(:db_path) { File.join(Dir.tmpdir, "coindcx_paper_broker_#{SecureRandom.hex(12)}.sqlite3") }
  let(:store) { CoindcxBot::Persistence::PaperStore.new(db_path) }
  let(:fill_engine) { CoindcxBot::Execution::FillEngine.new(slippage_bps: 5, fee_bps: 4) }
  subject(:broker) { described_class.new(store: store, fill_engine: fill_engine, logger: nil) }

  after do
    store.close
    File.delete(db_path) if File.exist?(db_path)
  end

  describe '#paper?' do
    it 'returns true' do
      expect(broker.paper?).to be true
    end
  end

  describe 'order book reconcile' do
    it 'loads working orders from the store on boot' do
      wid = store.insert_order(
        pair: 'B-SOL_USDT', side: 'long', order_type: 'limit', price: '100', quantity: '0.5', status: 'working',
        limit_price: '99'
      )
      broker2 = described_class.new(store: store, fill_engine: fill_engine, logger: nil)
      expect(broker2.order_book.size).to eq(1)
      expect(broker2.order_book.find(wid).limit_price).to eq(BigDecimal('99'))
    end
  end

  describe '#place_order' do
    it 'creates an order, fill, and position for a market entry' do
      result = broker.place_order(
        pair: 'B-SOL_USDT', side: 'long', quantity: BigDecimal('1'),
        ltp: BigDecimal('100'), order_type: :market
      )

      expect(result).to eq(:ok)
      expect(store.all_orders.size).to eq(1)
      expect(store.all_fills.size).to eq(1)
      expect(store.open_positions.size).to eq(1)
    end

    it 'applies slippage to the fill price for a long entry' do
      broker.place_order(
        pair: 'B-SOL_USDT', side: 'long', quantity: BigDecimal('1'),
        ltp: BigDecimal('100'), order_type: :market
      )

      fill = store.all_fills.first
      fill_price = BigDecimal(fill[:price])
      expect(fill_price).to be > BigDecimal('100')
    end

    it 'applies slippage to the fill price for a short entry' do
      broker.place_order(
        pair: 'B-SOL_USDT', side: 'short', quantity: BigDecimal('1'),
        ltp: BigDecimal('100'), order_type: :market
      )

      fill = store.all_fills.first
      fill_price = BigDecimal(fill[:price])
      expect(fill_price).to be < BigDecimal('100')
    end

    it 'records a fill event' do
      broker.place_order(
        pair: 'B-SOL_USDT', side: 'long', quantity: BigDecimal('1'),
        ltp: BigDecimal('100'), order_type: :market
      )

      events = store.recent_events(10)
      expect(events.any? { |e| e[:event_type] == 'order_filled' }).to be true
    end

    it 'charges a non-zero fee' do
      broker.place_order(
        pair: 'B-SOL_USDT', side: 'long', quantity: BigDecimal('1'),
        ltp: BigDecimal('100'), order_type: :market
      )

      fee = BigDecimal(store.all_fills.first[:fee])
      expect(fee).to be > 0
    end
  end

  describe '#close_position' do
    before do
      broker.place_order(
        pair: 'B-SOL_USDT', side: 'long', quantity: BigDecimal('1'),
        ltp: BigDecimal('100'), order_type: :market
      )
    end

    it 'closes the position and books realized PnL' do
      result = broker.close_position(
        pair: 'B-SOL_USDT', side: 'long', quantity: BigDecimal('1'), ltp: BigDecimal('110')
      )

      expect(result[:ok]).to be true
      expect(result[:realized_pnl_usdt]).to be_a(BigDecimal)
      expect(store.open_positions).to be_empty

      closed = store.all_positions.find { |p| p[:status] == 'closed' }
      realized = BigDecimal(closed[:realized_pnl])
      expect(realized).to be > 0
    end

    it 'deducts fee from realized PnL' do
      broker.close_position(
        pair: 'B-SOL_USDT', side: 'long', quantity: BigDecimal('1'), ltp: BigDecimal('110')
      )

      closed = store.all_positions.find { |p| p[:status] == 'closed' }
      realized = BigDecimal(closed[:realized_pnl])
      gross_pnl = (BigDecimal('110') - BigDecimal('100')) * BigDecimal('1')
      expect(realized).to be < gross_pnl
    end

    it 'returns no_position when pair has no open position' do
      result = broker.close_position(
        pair: 'B-ETH_USDT', side: 'long', quantity: BigDecimal('1'), ltp: BigDecimal('2000')
      )
      expect(result[:ok]).to be false
      expect(result[:reason]).to eq(:no_position)
    end
  end

  describe '#open_positions' do
    it 'returns normalized positions matching journal format' do
      broker.place_order(
        pair: 'B-SOL_USDT', side: 'long', quantity: BigDecimal('1'),
        ltp: BigDecimal('100'), order_type: :market
      )

      positions = broker.open_positions
      expect(positions.size).to eq(1)

      pos = positions.first
      expect(pos[:pair]).to eq('B-SOL_USDT')
      expect(pos[:side]).to eq('long')
      expect(pos[:state]).to eq('open')
      expect(pos).to have_key(:id)
    end
  end

  describe '#unrealized_pnl' do
    it 'computes mark-to-market PnL for long position' do
      broker.place_order(
        pair: 'B-SOL_USDT', side: 'long', quantity: BigDecimal('1'),
        ltp: BigDecimal('100'), order_type: :market
      )

      upnl = broker.unrealized_pnl('B-SOL_USDT' => BigDecimal('110'))
      expect(upnl).to be > 0
    end

    it 'computes mark-to-market PnL for short position' do
      broker.place_order(
        pair: 'B-SOL_USDT', side: 'short', quantity: BigDecimal('1'),
        ltp: BigDecimal('100'), order_type: :market
      )

      upnl = broker.unrealized_pnl('B-SOL_USDT' => BigDecimal('90'))
      expect(upnl).to be > 0
    end

    it 'returns zero with no open positions' do
      expect(broker.unrealized_pnl('B-SOL_USDT' => BigDecimal('100'))).to eq(BigDecimal('0'))
    end
  end

  describe '#metrics' do
    it 'returns aggregate broker statistics' do
      broker.place_order(
        pair: 'B-SOL_USDT', side: 'long', quantity: BigDecimal('1'),
        ltp: BigDecimal('100'), order_type: :market
      )

      m = broker.metrics
      expect(m[:total_fees]).to be > 0
      expect(m[:fill_count]).to eq(1)
      expect(m[:open_positions]).to eq(1)
      expect(m[:order_count]).to eq(1)
    end
  end

  describe 'long/short PnL symmetry' do
    it 'produces symmetric PnL for equal and opposite price moves' do
      zero_slip_engine = CoindcxBot::Execution::FillEngine.new(slippage_bps: 0, fee_bps: 0)
      zero_broker = described_class.new(store: store, fill_engine: zero_slip_engine, logger: nil)

      zero_broker.place_order(
        pair: 'B-SOL_USDT', side: 'long', quantity: BigDecimal('1'),
        ltp: BigDecimal('100'), order_type: :market
      )
      zero_broker.close_position(
        pair: 'B-SOL_USDT', side: 'long', quantity: BigDecimal('1'), ltp: BigDecimal('110')
      )

      long_pnl = BigDecimal(store.all_positions.find { |p| p[:status] == 'closed' && p[:side] == 'long' }[:realized_pnl])

      zero_broker.place_order(
        pair: 'B-ETH_USDT', side: 'short', quantity: BigDecimal('1'),
        ltp: BigDecimal('100'), order_type: :market
      )
      zero_broker.close_position(
        pair: 'B-ETH_USDT', side: 'short', quantity: BigDecimal('1'), ltp: BigDecimal('90')
      )

      short_pnl = BigDecimal(store.all_positions.find { |p| p[:status] == 'closed' && p[:side] == 'short' }[:realized_pnl])

      expect(long_pnl).to eq(short_pnl)
    end
  end

  describe '#cancel_order' do
    it 'marks the order as canceled' do
      order_id = store.insert_order(pair: 'B-SOL_USDT', side: 'long', order_type: 'market', price: '100', quantity: '1')
      broker.cancel_order(order_id)

      expect(store.find_order(order_id)[:status]).to eq('canceled')
    end
  end

  describe '#process_tick' do
    let(:zero_engine) { CoindcxBot::Execution::FillEngine.new(slippage_bps: 0, fee_bps: 0) }

    it 'fills a working limit entry, opens a position, and removes the order from the book' do
      store.insert_order(
        pair: 'B-SOL_USDT', side: 'long', order_type: 'limit', price: '100', quantity: '1', status: 'working',
        limit_price: '98'
      )
      tick_broker = described_class.new(store: store, fill_engine: zero_engine, logger: nil)
      expect(tick_broker.order_book.size).to eq(1)

      results = tick_broker.process_tick(pair: 'B-SOL_USDT', ltp: BigDecimal('98'))

      expect(results.size).to eq(1)
      expect(results.first[:kind]).to eq(:entry)
      expect(store.open_positions.size).to eq(1)
      expect(tick_broker.order_book.size).to eq(0)
      expect(store.find_order(results.first[:order_id])[:status]).to eq('filled')
      expect(store.recent_events(20).any? { |e| e[:event_type] == 'order_filled' }).to be true
    end

    it 'fills a stop exit and closes the position when sync_order_book! picks up a working exit' do
      tick_broker = described_class.new(store: store, fill_engine: zero_engine, logger: nil)
      tick_broker.place_order(
        pair: 'B-SOL_USDT', side: 'long', quantity: BigDecimal('1'),
        ltp: BigDecimal('100'), order_type: :market
      )

      store.insert_order(
        pair: 'B-SOL_USDT', side: 'sell', order_type: 'stop_market', price: '100', quantity: '1', status: 'working',
        stop_price: '95'
      )
      tick_broker.sync_order_book!
      expect(tick_broker.order_book.size).to eq(1)

      results = tick_broker.process_tick(pair: 'B-SOL_USDT', ltp: BigDecimal('95'))

      expect(results.size).to eq(1)
      expect(results.first[:kind]).to eq(:exit)
      expect(results.first[:realized_pnl_usdt]).to be_a(BigDecimal)
      expect(store.open_positions).to be_empty
      expect(tick_broker.order_book.size).to eq(0)
      expect(store.recent_events(30).any? { |e| e[:event_type] == 'position_closed' }).to be true
    end

    it 'returns an empty array when there are no working orders' do
      expect(broker.process_tick(pair: 'B-SOL_USDT', ltp: BigDecimal('100'))).to eq([])
    end
  end
end
