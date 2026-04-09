# frozen_string_literal: true

RSpec.describe CoindcxBot::Execution::Coordinator do
  let(:journal_path) { Tempfile.new(['coord', '.sqlite3']).path }
  let(:journal) { CoindcxBot::Persistence::Journal.new(journal_path) }
  let(:orders) { instance_double(CoindcxBot::Gateways::OrderGateway) }
  let(:account) { instance_double(CoindcxBot::Gateways::AccountGateway) }

  let(:config) do
    CoindcxBot::Config.new(
      minimal_bot_config(
        runtime: { dry_run: false, journal_path: journal_path },
        risk: { max_leverage: 3, per_trade_inr_min: 250, per_trade_inr_max: 500 },
        execution: { order_defaults: { leverage: 50, margin_currency_short_name: 'USDT', order_type: 'market_order' } }
      )
    )
  end

  let(:guard) { CoindcxBot::Risk::ExposureGuard.new(config: config) }

  subject(:coordinator) do
    described_class.new(
      order_gateway: orders,
      account_gateway: account,
      journal: journal,
      config: config,
      exposure_guard: guard,
      logger: nil
    )
  end

  after do
    journal.close
    File.delete(journal_path) if File.exist?(journal_path)
  end

  it 'sends leverage capped by max_leverage on open' do
    signal = CoindcxBot::Strategy::Signal.new(
      action: :open_long,
      pair: 'B-SOL_USDT',
      side: :long,
      stop_price: BigDecimal('90'),
      reason: 'test',
      metadata: {}
    )

    expect(orders).to receive(:create) do |args|
      expect(args[:order][:leverage]).to eq(3)
      expect(args[:order][:total_quantity]).to eq('0.01')
      CoindcxBot::Gateways::Result.ok({})
    end

    coordinator.apply(signal, quantity: BigDecimal('0.01'), entry_price: BigDecimal('100'))
  end

  context 'when dry_run' do
    let(:config) do
      CoindcxBot::Config.new(
        minimal_bot_config(
          runtime: { dry_run: true, journal_path: journal_path },
          risk: { max_leverage: 3, per_trade_inr_min: 250, per_trade_inr_max: 500 },
          execution: { order_defaults: { leverage: 50, margin_currency_short_name: 'USDT', order_type: 'market_order' } }
        )
      )
    end

    it 'inserts an open position in the journal without calling the order gateway' do
      signal = CoindcxBot::Strategy::Signal.new(
        action: :open_long,
        pair: 'B-SOL_USDT',
        side: :long,
        stop_price: BigDecimal('90'),
        reason: 'test',
        metadata: {}
      )

      expect(orders).not_to receive(:create)
      expect(coordinator.apply(signal, quantity: BigDecimal('0.01'), entry_price: BigDecimal('100'))).to eq(:dry_run)

      rows = journal.open_positions
      expect(rows.size).to eq(1)
      expect(rows.first[:pair]).to eq('B-SOL_USDT')
      expect(rows.first[:side]).to eq('long')
      expect(rows.first[:entry_price]).to eq('100.0')
      expect(rows.first[:state]).to eq('open')
    end

    it 'closes the journal row on close without touching the account gateway' do
      open_signal = CoindcxBot::Strategy::Signal.new(
        action: :open_short,
        pair: 'B-ETH_USDT',
        side: :short,
        stop_price: BigDecimal('2000'),
        reason: 'test',
        metadata: {}
      )
      coordinator.apply(open_signal, quantity: BigDecimal('0.02'), entry_price: BigDecimal('1900'))

      id = journal.open_positions.first[:id]

      close_signal = CoindcxBot::Strategy::Signal.new(
        action: :close,
        pair: 'B-ETH_USDT',
        side: :short,
        stop_price: nil,
        reason: 'test_exit',
        metadata: { position_id: id }
      )

      expect(account).not_to receive(:list_positions)
      expect(coordinator.apply(close_signal)).to eq(:dry_run)

      expect(journal.open_positions).to be_empty
      close_logged = journal.recent_events(10).any? do |row|
        row['type'] == 'signal_close' && JSON.parse(row['payload'])['position_id'] == id
      end
      expect(close_logged).to be(true)
    end

    it 'records approximate realized PnL in INR when closing with exit_price' do
      open_signal = CoindcxBot::Strategy::Signal.new(
        action: :open_long,
        pair: 'B-SOL_USDT',
        side: :long,
        stop_price: BigDecimal('90'),
        reason: 'test',
        metadata: {}
      )
      coordinator.apply(open_signal, quantity: BigDecimal('0.5'), entry_price: BigDecimal('100'))

      id = journal.open_positions.first[:id]
      close_signal = CoindcxBot::Strategy::Signal.new(
        action: :close,
        pair: 'B-SOL_USDT',
        side: :long,
        stop_price: nil,
        reason: 'tp',
        metadata: { position_id: id }
      )

      coordinator.apply(close_signal, exit_price: BigDecimal('110'))

      expect(journal.daily_pnl_inr).to eq(BigDecimal('415')) # (110-100)*0.5 USDT * 83 INR/USDT
    end

    it 'returns failed when position_id does not match an open row' do
      close_signal = CoindcxBot::Strategy::Signal.new(
        action: :close,
        pair: 'B-SOL_USDT',
        side: :long,
        stop_price: nil,
        reason: 'x',
        metadata: { position_id: 99_999 }
      )
      expect(coordinator.apply(close_signal)).to eq(:failed)
    end

    it 'closes the open row by pair when position_id is missing (paper only)' do
      open_signal = CoindcxBot::Strategy::Signal.new(
        action: :open_short,
        pair: 'B-ETH_USDT',
        side: :short,
        stop_price: BigDecimal('2100'),
        reason: 'test',
        metadata: {}
      )
      coordinator.apply(open_signal, quantity: BigDecimal('0.01'), entry_price: BigDecimal('2000'))

      close_signal = CoindcxBot::Strategy::Signal.new(
        action: :close,
        pair: 'B-ETH_USDT',
        side: :short,
        stop_price: nil,
        reason: 'manual',
        metadata: {}
      )

      expect(coordinator.apply(close_signal, exit_price: BigDecimal('1900'))).to eq(:dry_run)
      expect(journal.open_positions).to be_empty
    end
  end
end
