# frozen_string_literal: true

require 'securerandom'

RSpec.describe CoindcxBot::Execution::PaperBroker, 'funding fees' do
  let(:db_path) { File.join(Dir.tmpdir, "coindcx_funding_#{SecureRandom.hex(12)}.sqlite3") }
  let(:store) { CoindcxBot::Persistence::PaperStore.new(db_path) }
  let(:zero_engine) { CoindcxBot::Execution::FillEngine.new(slippage_bps: 0, fee_bps: 0) }

  after do
    store.close
    File.delete(db_path) if File.exist?(db_path)
  end

  describe 'funding fee accrual' do
    it 'accrues funding fee when interval has elapsed' do
      # Set funding rate to 10 bps (0.1%) for easy math, and set last_funding 8h+ ago
      broker = described_class.new(
        store: store,
        fill_engine: zero_engine,
        logger: nil,
        funding_rate_bps: 10
      )
      # Force the interval to have elapsed for this pair
      broker.instance_variable_get(:@last_funding_at)['B-SOL_USDT'] = Time.now - CoindcxBot::Execution::PaperBroker::FUNDING_INTERVAL_SECONDS - 1

      broker.place_order(
        pair: 'B-SOL_USDT', side: 'long', quantity: BigDecimal('10'),
        ltp: BigDecimal('100'), order_type: :market
      )

      # Trigger tick to accrue funding
      broker.process_tick(pair: 'B-SOL_USDT', ltp: BigDecimal('100'))

      total_funding = store.total_funding_fees
      # position_value = 100 * 10 = 1000, rate = 10/10000 = 0.001, fee = 1.0
      expect(total_funding).to eq(BigDecimal('1'))
    end

    it 'does NOT accrue funding if interval has not elapsed' do
      broker = described_class.new(
        store: store,
        fill_engine: zero_engine,
        logger: nil,
        funding_rate_bps: 10
      )

      broker.place_order(
        pair: 'B-SOL_USDT', side: 'long', quantity: BigDecimal('10'),
        ltp: BigDecimal('100'), order_type: :market
      )

      # Tick immediately — no interval elapsed
      broker.process_tick(pair: 'B-SOL_USDT', ltp: BigDecimal('100'))

      expect(store.total_funding_fees).to eq(BigDecimal('0'))
    end

    it 'deducts accumulated funding fees from realized PnL on close' do
      broker = described_class.new(
        store: store,
        fill_engine: zero_engine,
        logger: nil,
        funding_rate_bps: 10
      )

      broker.place_order(
        pair: 'B-SOL_USDT', side: 'long', quantity: BigDecimal('10'),
        ltp: BigDecimal('100'), order_type: :market
      )

      # Manually insert a funding fee to simulate accrual
      pos = store.open_position_for('B-SOL_USDT')
      store.insert_funding_fee(
        pair: 'B-SOL_USDT',
        position_id: pos[:id],
        amount: BigDecimal('2'),
        rate: BigDecimal('0.001'),
        position_value: BigDecimal('1000')
      )

      result = broker.close_position(
        pair: 'B-SOL_USDT', side: 'long', quantity: BigDecimal('10'), ltp: BigDecimal('110')
      )

      # Gross PnL = (110-100)*10 = 100, minus funding 2 = 98
      expect(result[:ok]).to be true
      expect(result[:realized_pnl_usdt]).to eq(BigDecimal('98'))
    end
  end

  describe '#metrics' do
    it 'includes total_funding_fees' do
      broker = described_class.new(store: store, fill_engine: zero_engine, logger: nil)
      m = broker.metrics
      expect(m).to have_key(:total_funding_fees)
      expect(m[:total_funding_fees]).to eq(BigDecimal('0'))
    end
  end

  describe '#record_snapshot' do
    it 'records an equity snapshot to the store' do
      broker = described_class.new(store: store, fill_engine: zero_engine, logger: nil)

      broker.place_order(
        pair: 'B-SOL_USDT', side: 'long', quantity: BigDecimal('1'),
        ltp: BigDecimal('100'), order_type: :market
      )

      broker.record_snapshot('B-SOL_USDT' => BigDecimal('110'))

      snap = store.latest_snapshot
      expect(snap).not_to be_nil
      expect(BigDecimal(snap[:unrealized_pnl])).to eq(BigDecimal('10'))
    end
  end
end
