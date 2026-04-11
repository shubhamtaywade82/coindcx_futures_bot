# frozen_string_literal: true

require 'securerandom'

RSpec.describe CoindcxBot::Execution::PaperBroker, 'bracket orders & OCO' do
  let(:db_path) { File.join(Dir.tmpdir, "coindcx_bracket_#{SecureRandom.hex(12)}.sqlite3") }
  let(:store) { CoindcxBot::Persistence::PaperStore.new(db_path) }
  let(:zero_engine) { CoindcxBot::Execution::FillEngine.new(slippage_bps: 0, fee_bps: 0) }
  let(:real_engine) { CoindcxBot::Execution::FillEngine.new(slippage_bps: 5, fee_bps: 4) }
  subject(:broker) { described_class.new(store: store, fill_engine: zero_engine, logger: nil) }

  after do
    store.close
    File.delete(db_path) if File.exist?(db_path)
  end

  describe '#place_bracket_order' do
    it 'creates entry fill + SL working order + TP working order as an OCO group' do
      result = broker.place_bracket_order(
        { pair: 'B-SOL_USDT', side: 'long', quantity: BigDecimal('1'), ltp: BigDecimal('100') },
        sl_price: BigDecimal('90'),
        tp_price: BigDecimal('130')
      )

      expect(result[:ok]).to be true
      expect(result[:entry_order_id]).to be_a(Integer)
      expect(result[:sl_order_id]).to be_a(Integer)
      expect(result[:tp_order_id]).to be_a(Integer)
      expect(result[:group_id]).to be_a(Integer)

      # Entry should be filled
      entry = store.find_order(result[:entry_order_id])
      expect(entry[:status]).to eq('filled')

      # SL should be working
      sl = store.find_order(result[:sl_order_id])
      expect(sl[:status]).to eq('working')
      expect(sl[:order_type]).to eq('stop_market')
      expect(sl[:side]).to eq('sell') # opposite of long

      # TP should be working
      tp = store.find_order(result[:tp_order_id])
      expect(tp[:status]).to eq('working')
      expect(tp[:order_type]).to eq('take_profit_market')
      expect(tp[:side]).to eq('sell')

      # Position should exist
      expect(store.open_positions.size).to eq(1)

      # OrderBook should have 2 working orders
      expect(broker.order_book.size).to eq(2)

      # Group should be active
      group = store.find_order_group(result[:group_id])
      expect(group[:status]).to eq('active')
      expect(group[:entry_order_id]).to eq(result[:entry_order_id])
      expect(group[:sl_order_id]).to eq(result[:sl_order_id])
      expect(group[:tp_order_id]).to eq(result[:tp_order_id])
    end

    it 'creates bracket without TP when tp_price is nil' do
      result = broker.place_bracket_order(
        { pair: 'B-SOL_USDT', side: 'long', quantity: BigDecimal('1'), ltp: BigDecimal('100') },
        sl_price: BigDecimal('90')
      )

      expect(result[:ok]).to be true
      expect(result[:sl_order_id]).to be_a(Integer)
      expect(result[:tp_order_id]).to be_nil
      expect(broker.order_book.size).to eq(1)
    end

    it 'stores stop_price on the position' do
      broker.place_bracket_order(
        { pair: 'B-SOL_USDT', side: 'long', quantity: BigDecimal('1'), ltp: BigDecimal('100') },
        sl_price: BigDecimal('90')
      )

      pos = store.open_position_for('B-SOL_USDT')
      expect(BigDecimal(pos[:stop_price])).to eq(BigDecimal('90'))
    end

    it 'works for short entries with inverted SL/TP sides' do
      result = broker.place_bracket_order(
        { pair: 'B-SOL_USDT', side: 'short', quantity: BigDecimal('1'), ltp: BigDecimal('100') },
        sl_price: BigDecimal('110'),
        tp_price: BigDecimal('70')
      )

      sl = store.find_order(result[:sl_order_id])
      expect(sl[:side]).to eq('buy') # opposite of short

      tp = store.find_order(result[:tp_order_id])
      expect(tp[:side]).to eq('buy')
    end
  end

  describe 'OCO cancellation on SL fill' do
    it 'cancels TP when SL fills via process_tick' do
      result = broker.place_bracket_order(
        { pair: 'B-SOL_USDT', side: 'long', quantity: BigDecimal('1'), ltp: BigDecimal('100') },
        sl_price: BigDecimal('90'),
        tp_price: BigDecimal('130')
      )

      # Price drops to SL
      fills = broker.process_tick(pair: 'B-SOL_USDT', ltp: BigDecimal('90'))

      expect(fills.size).to eq(1)
      expect(fills.first[:kind]).to eq(:exit)
      expect(fills.first[:trigger]).to eq(:stop_loss)

      # TP should be canceled
      tp = store.find_order(result[:tp_order_id])
      expect(tp[:status]).to eq('canceled')

      # OrderBook should be empty
      expect(broker.order_book.size).to eq(0)

      # Position should be closed
      expect(store.open_positions).to be_empty

      # Group should be completed
      group = store.find_order_group(result[:group_id])
      expect(group[:status]).to eq('completed')
    end
  end

  describe 'OCO cancellation on TP fill' do
    it 'cancels SL when TP fills via process_tick' do
      result = broker.place_bracket_order(
        { pair: 'B-SOL_USDT', side: 'long', quantity: BigDecimal('1'), ltp: BigDecimal('100') },
        sl_price: BigDecimal('90'),
        tp_price: BigDecimal('130')
      )

      # Price rises to TP
      fills = broker.process_tick(pair: 'B-SOL_USDT', ltp: BigDecimal('130'))

      expect(fills.size).to eq(1)
      expect(fills.first[:kind]).to eq(:exit)
      expect(fills.first[:trigger]).to eq(:take_profit)

      # SL should be canceled
      sl = store.find_order(result[:sl_order_id])
      expect(sl[:status]).to eq('canceled')

      # Position should be closed
      expect(store.open_positions).to be_empty
    end
  end

  describe 'manual close cancels bracket orders' do
    it 'cancels SL and TP when close_position is called' do
      result = broker.place_bracket_order(
        { pair: 'B-SOL_USDT', side: 'long', quantity: BigDecimal('1'), ltp: BigDecimal('100') },
        sl_price: BigDecimal('90'),
        tp_price: BigDecimal('130')
      )

      broker.close_position(pair: 'B-SOL_USDT', side: 'long', quantity: BigDecimal('1'),
                            ltp: BigDecimal('115'))

      sl = store.find_order(result[:sl_order_id])
      tp = store.find_order(result[:tp_order_id])
      expect(sl[:status]).to eq('canceled')
      expect(tp[:status]).to eq('canceled')
      expect(broker.order_book.size).to eq(0)
    end
  end

  describe 'PnL with fees on bracket exit' do
    subject(:fee_broker) { described_class.new(store: store, fill_engine: real_engine, logger: nil) }

    it 'deducts fees from realized PnL on SL exit' do
      fee_broker.place_bracket_order(
        { pair: 'B-SOL_USDT', side: 'long', quantity: BigDecimal('1'), ltp: BigDecimal('100') },
        sl_price: BigDecimal('95'),
        tp_price: BigDecimal('110')
      )

      fills = fee_broker.process_tick(pair: 'B-SOL_USDT', ltp: BigDecimal('95'))

      expect(fills.size).to eq(1)
      pnl = fills.first[:realized_pnl_usdt]
      expect(pnl).to be < BigDecimal('0') # loss + fees
    end
  end

  describe 'short bracket full lifecycle' do
    it 'SL triggers on price rise for short position' do
      broker.place_bracket_order(
        { pair: 'B-SOL_USDT', side: 'short', quantity: BigDecimal('1'), ltp: BigDecimal('100') },
        sl_price: BigDecimal('110'),
        tp_price: BigDecimal('70')
      )

      # Price rises to SL
      fills = broker.process_tick(pair: 'B-SOL_USDT', ltp: BigDecimal('110'))

      expect(fills.size).to eq(1)
      expect(fills.first[:kind]).to eq(:exit)
      expect(fills.first[:realized_pnl_usdt]).to eq(BigDecimal('-10')) # 100-110 * 1
      expect(store.open_positions).to be_empty
    end

    it 'TP triggers on price drop for short position' do
      broker.place_bracket_order(
        { pair: 'B-SOL_USDT', side: 'short', quantity: BigDecimal('1'), ltp: BigDecimal('100') },
        sl_price: BigDecimal('110'),
        tp_price: BigDecimal('70')
      )

      # Price drops to TP
      fills = broker.process_tick(pair: 'B-SOL_USDT', ltp: BigDecimal('70'))

      expect(fills.size).to eq(1)
      expect(fills.first[:kind]).to eq(:exit)
      expect(fills.first[:realized_pnl_usdt]).to eq(BigDecimal('30')) # 100-70 * 1
      expect(store.open_positions).to be_empty
    end
  end
end
