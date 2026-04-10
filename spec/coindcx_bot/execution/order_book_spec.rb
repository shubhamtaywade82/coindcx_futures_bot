# frozen_string_literal: true

require 'securerandom'

RSpec.describe CoindcxBot::Execution::OrderBook do
  let(:db_path) { File.join(Dir.tmpdir, "coindcx_order_book_#{SecureRandom.hex(12)}.sqlite3") }
  let(:store) { CoindcxBot::Persistence::PaperStore.new(db_path) }

  after do
    store.close
    File.delete(db_path) if File.exist?(db_path)
  end

  it 'reconciles working rows from PaperStore' do
    id = store.insert_order(
      pair: 'B-SOL_USDT', side: 'long', order_type: 'limit', price: '100', quantity: '1',
      status: 'working', limit_price: '99'
    )
    book = described_class.new.reconcile_from_store(store)
    expect(book.size).to eq(1)
    wo = book.find(id)
    expect(wo.pair).to eq('B-SOL_USDT')
    expect(wo.limit_price).to eq(BigDecimal('99'))
    expect(wo.anchor_price).to eq(BigDecimal('100'))
    expect(wo.placed_at).to be_a(Time)
  end

  it 'removes an order and clears on clear' do
    id = store.insert_order(
      pair: 'B-SOL_USDT', side: 'long', order_type: 'market', price: '100', quantity: '1',
      status: 'accepted'
    )
    book = described_class.new.reconcile_from_store(store)
    book.remove(id)
    expect(book.size).to eq(0)
    book.add(9, pair: 'B-ETH_USDT', side: 'short', order_type: 'stop', quantity: '0.1',
               anchor_price: BigDecimal('2000'), stop_price: BigDecimal('2050'))
    expect(book.working_for('B-ETH_USDT').size).to eq(1)
    book.clear
    expect(book.size).to eq(0)
  end

  it 'updates stop price' do
    book = described_class.new
    book.add(1, pair: 'B-SOL_USDT', side: 'sell', order_type: 'stop_market', quantity: '1',
             stop_price: BigDecimal('95'))
    placed_before = book.find(1).placed_at
    book.update_stop(1, BigDecimal('96'))
    expect(book.find(1).stop_price).to eq(BigDecimal('96'))
    expect(book.find(1).placed_at).to eq(placed_before)
  end
end
