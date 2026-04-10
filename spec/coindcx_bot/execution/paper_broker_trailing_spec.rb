# frozen_string_literal: true

require 'securerandom'

RSpec.describe CoindcxBot::Execution::PaperBroker, 'trailing stops' do
  let(:db_path) { File.join(Dir.tmpdir, "coindcx_trail_#{SecureRandom.hex(12)}.sqlite3") }
  let(:store) { CoindcxBot::Persistence::PaperStore.new(db_path) }
  let(:zero_engine) { CoindcxBot::Execution::FillEngine.new(slippage_bps: 0, fee_bps: 0) }
  subject(:broker) { described_class.new(store: store, fill_engine: zero_engine, logger: nil) }

  after do
    store.close
    File.delete(db_path) if File.exist?(db_path)
  end

  describe '#update_trailing_stop' do
    it 'updates the working SL order stop price and position stop_price' do
      result = broker.place_bracket_order(
        { pair: 'B-SOL_USDT', side: 'long', quantity: BigDecimal('1'), ltp: BigDecimal('100') },
        sl_price: BigDecimal('90')
      )

      broker.update_trailing_stop(pair: 'B-SOL_USDT', new_stop: BigDecimal('95'))

      sl_order = broker.order_book.find(result[:sl_order_id])
      expect(sl_order.stop_price).to eq(BigDecimal('95'))

      pos = store.open_position_for('B-SOL_USDT')
      expect(BigDecimal(pos[:stop_price])).to eq(BigDecimal('95'))
      expect(BigDecimal(pos[:trail_price])).to eq(BigDecimal('95'))
    end

    it 'does nothing when no active group exists' do
      # No position, no group
      expect { broker.update_trailing_stop(pair: 'B-SOL_USDT', new_stop: BigDecimal('95')) }
        .not_to raise_error
    end
  end

  describe 'auto-trailing via process_tick' do
    it 'ratchets SL up for long when price moves > 1R into profit' do
      broker.place_bracket_order(
        { pair: 'B-SOL_USDT', side: 'long', quantity: BigDecimal('1'), ltp: BigDecimal('100') },
        sl_price: BigDecimal('90')
      )

      # Risk = 10 (100-90). Price at 115 = 1.5R profit.
      # Trail should move stop: entry + 50% of profit = 100 + 7.5 = 107.5
      broker.process_tick(pair: 'B-SOL_USDT', ltp: BigDecimal('115'))

      pos = store.open_position_for('B-SOL_USDT')
      new_stop = BigDecimal(pos[:stop_price])
      expect(new_stop).to be > BigDecimal('90')
      expect(new_stop).to eq(BigDecimal('100') + (BigDecimal('15') * BigDecimal('0.5')))
    end

    it 'does NOT trail when price is less than 1R in profit' do
      broker.place_bracket_order(
        { pair: 'B-SOL_USDT', side: 'long', quantity: BigDecimal('1'), ltp: BigDecimal('100') },
        sl_price: BigDecimal('90')
      )

      # Price at 105 = 0.5R profit. Should NOT trail.
      broker.process_tick(pair: 'B-SOL_USDT', ltp: BigDecimal('105'))

      pos = store.open_position_for('B-SOL_USDT')
      expect(BigDecimal(pos[:stop_price])).to eq(BigDecimal('90'))
    end

    it 'never ratchets SL backwards (only forward for longs)' do
      broker.place_bracket_order(
        { pair: 'B-SOL_USDT', side: 'long', quantity: BigDecimal('1'), ltp: BigDecimal('100') },
        sl_price: BigDecimal('90')
      )

      # Push price high to trail (120 → stop at 110)
      broker.process_tick(pair: 'B-SOL_USDT', ltp: BigDecimal('120'))
      pos1 = store.open_position_for('B-SOL_USDT')
      stop1 = BigDecimal(pos1[:stop_price])

      # Price drops but stays ABOVE trailed stop; stop should not move down
      broker.process_tick(pair: 'B-SOL_USDT', ltp: BigDecimal('112'))
      pos2 = store.open_position_for('B-SOL_USDT')
      stop2 = BigDecimal(pos2[:stop_price])

      expect(stop2).to be >= stop1
    end

    it 'trails SL down for short when price moves in profit' do
      broker.place_bracket_order(
        { pair: 'B-SOL_USDT', side: 'short', quantity: BigDecimal('1'), ltp: BigDecimal('100') },
        sl_price: BigDecimal('110')
      )

      # Risk = 10. Price at 85 = 1.5R profit for short.
      # Trail should move stop: entry - 50% of profit = 100 - 7.5 = 92.5
      broker.process_tick(pair: 'B-SOL_USDT', ltp: BigDecimal('85'))

      pos = store.open_position_for('B-SOL_USDT')
      new_stop = BigDecimal(pos[:stop_price])
      expect(new_stop).to be < BigDecimal('110')
      expect(new_stop).to eq(BigDecimal('100') - (BigDecimal('15') * BigDecimal('0.5')))
    end

    it 'eventually fills SL after trailing when price reverses' do
      broker.place_bracket_order(
        { pair: 'B-SOL_USDT', side: 'long', quantity: BigDecimal('1'), ltp: BigDecimal('100') },
        sl_price: BigDecimal('90'),
        tp_price: BigDecimal('200') # far away TP
      )

      # Rally to 130, trail moves stop up
      broker.process_tick(pair: 'B-SOL_USDT', ltp: BigDecimal('130'))
      pos = store.open_position_for('B-SOL_USDT')
      trailed_stop = BigDecimal(pos[:stop_price])
      expect(trailed_stop).to be > BigDecimal('90')

      # Reversal: price drops to trailed stop → exit
      fills = broker.process_tick(pair: 'B-SOL_USDT', ltp: trailed_stop)

      expect(fills.size).to eq(1)
      expect(fills.first[:kind]).to eq(:exit)
      expect(fills.first[:trigger]).to eq(:stop_loss)
      expect(store.open_positions).to be_empty

      # PnL should be positive (exited above entry via trail)
      expect(fills.first[:realized_pnl_usdt]).to be > BigDecimal('0')
    end
  end
end
