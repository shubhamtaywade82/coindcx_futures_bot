# frozen_string_literal: true

require 'securerandom'

RSpec.describe CoindcxBot::Execution::Coordinator do
  let(:journal_path) { File.join(Dir.tmpdir, "coindcx_coord_journal_#{SecureRandom.hex(12)}.sqlite3") }
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

  let(:broker) do
    CoindcxBot::Execution::LiveBroker.new(
      order_gateway: orders,
      account_gateway: account,
      journal: journal,
      config: config,
      exposure_guard: guard,
      logger: nil
    )
  end

  subject(:coordinator) do
    described_class.new(
      broker: broker,
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

  context 'when paper mode' do
    let(:paper_store_path) { File.join(Dir.tmpdir, "coindcx_coord_paper_#{SecureRandom.hex(12)}.sqlite3") }
    let(:paper_store) { CoindcxBot::Persistence::PaperStore.new(paper_store_path) }
    let(:fill_engine) { CoindcxBot::Execution::FillEngine.new(slippage_bps: 5, fee_bps: 4) }

    let(:config) do
      CoindcxBot::Config.new(
        minimal_bot_config(
          runtime: { dry_run: true, journal_path: journal_path },
          risk: { max_leverage: 3, per_trade_inr_min: 250, per_trade_inr_max: 500 },
          execution: { order_defaults: { leverage: 50, margin_currency_short_name: 'USDT', order_type: 'market_order' } }
        )
      )
    end

    let(:broker) do
      CoindcxBot::Execution::PaperBroker.new(store: paper_store, fill_engine: fill_engine, logger: nil)
    end

    after do
      paper_store.close
      File.delete(paper_store_path) if File.exist?(paper_store_path)
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
      expect(coordinator.apply(signal, quantity: BigDecimal('0.01'), entry_price: BigDecimal('100'))).to eq(:paper)

      rows = journal.open_positions
      expect(rows.size).to eq(1)
      expect(rows.first[:pair]).to eq('B-SOL_USDT')
      expect(rows.first[:side]).to eq('long')
      paper_entry = BigDecimal(broker.open_position_for('B-SOL_USDT')[:entry_price].to_s)
      expect(BigDecimal(rows.first[:entry_price])).to eq(paper_entry)
      expect(paper_entry).to be > BigDecimal('100')
      expect(rows.first[:state]).to eq('open')
    end

    it 'records a paper fill in the paper store' do
      signal = CoindcxBot::Strategy::Signal.new(
        action: :open_long,
        pair: 'B-SOL_USDT',
        side: :long,
        stop_price: BigDecimal('90'),
        reason: 'test',
        metadata: {}
      )

      coordinator.apply(signal, quantity: BigDecimal('0.5'), entry_price: BigDecimal('100'))

      fills = paper_store.all_fills
      expect(fills.size).to eq(1)
      expect(BigDecimal(fills.first[:fee])).to be > 0
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
      expect(coordinator.apply(close_signal, exit_price: BigDecimal('1800'))).to eq(:paper)

      expect(journal.open_positions).to be_empty
    end

    it 'books daily INR from paper broker realized USDT on close' do
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

      closed = paper_store.all_positions.find { |p| p[:pair] == 'B-SOL_USDT' && p[:status] == 'closed' }
      usdt = BigDecimal(closed[:realized_pnl])
      expect(journal.daily_pnl_inr).to eq(usdt * config.inr_per_usdt)
    end

    it 'closes PaperStore and journal on flatten when LTP is provided' do
      open_signal = CoindcxBot::Strategy::Signal.new(
        action: :open_long,
        pair: 'B-SOL_USDT',
        side: :long,
        stop_price: BigDecimal('90'),
        reason: 'test',
        metadata: {}
      )
      coordinator.apply(open_signal, quantity: BigDecimal('0.1'), entry_price: BigDecimal('100'))

      expect(paper_store.open_positions.size).to eq(1)
      coordinator.flatten_all(['B-SOL_USDT'], ltps: { 'B-SOL_USDT' => BigDecimal('102') })

      expect(journal.open_positions).to be_empty
      expect(paper_store.open_positions).to be_empty
    end

    it 'skips PaperStore close on flatten when LTP is missing but still closes journal' do
      open_signal = CoindcxBot::Strategy::Signal.new(
        action: :open_long,
        pair: 'B-SOL_USDT',
        side: :long,
        stop_price: BigDecimal('90'),
        reason: 'test',
        metadata: {}
      )
      coordinator.apply(open_signal, quantity: BigDecimal('0.1'), entry_price: BigDecimal('100'))

      coordinator.flatten_all(['B-SOL_USDT'], ltps: {})

      expect(journal.open_positions).to be_empty
      expect(paper_store.open_positions.size).to eq(1)
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

      expect(coordinator.apply(close_signal, exit_price: BigDecimal('1900'))).to eq(:paper)
      expect(journal.open_positions).to be_empty
    end
  end

  context 'when gateway paper broker' do
    let(:config) do
      CoindcxBot::Config.new(
        minimal_bot_config(
          runtime: { dry_run: true, journal_path: journal_path },
          risk: { max_leverage: 3, per_trade_inr_min: 250, per_trade_inr_max: 500 },
          execution: { order_defaults: { leverage: 50, margin_currency_short_name: 'USDT', order_type: 'market_order' } }
        )
      )
    end

    let(:broker) do
      CoindcxBot::Execution::GatewayPaperBroker.new(
        order_gateway: orders,
        account_gateway: account,
        journal: journal,
        config: config,
        exposure_guard: guard,
        logger: nil,
        tick_base_url: 'http://127.0.0.1:9',
        tick_path: '/exchange/v1/paper/simulation/tick',
        api_key: 'k',
        api_secret: 's'
      )
    end

    it 'exits on the paper exchange when LTP is nil and books INR from the API payload' do
      jid = journal.insert_position(
        pair: 'B-ETH_USDT',
        side: 'long',
        entry_price: BigDecimal('2100'),
        quantity: BigDecimal('0.01'),
        stop_price: BigDecimal('2000'),
        trail_price: nil
      )

      allow(account).to receive(:list_positions).and_return(
        CoindcxBot::Gateways::Result.ok('positions' => [{ 'pair' => 'B-ETH_USDT', 'id' => '42' }])
      )
      allow(account).to receive(:exit_position).and_return(
        CoindcxBot::Gateways::Result.ok('realized_pnl_usdt' => '-1.25', 'fill_price' => '2088.5')
      )

      close_signal = CoindcxBot::Strategy::Signal.new(
        action: :close,
        pair: 'B-ETH_USDT',
        side: :long,
        stop_price: nil,
        reason: 'test',
        metadata: { position_id: jid }
      )

      coordinator.apply(close_signal, exit_price: nil)

      expect(account).to have_received(:exit_position).with(hash_including(id: '42'))
      expect(journal.open_positions).to be_empty
      expect(journal.daily_pnl_inr).to eq(BigDecimal('-1.25') * config.inr_per_usdt)
    end
  end
end
