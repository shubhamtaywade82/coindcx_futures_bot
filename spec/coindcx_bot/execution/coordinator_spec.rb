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
  let(:fx) { instance_double(CoindcxBot::Fx::UsdtInrRate, inr_per_usdt: config.inr_per_usdt) }

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
      logger: nil,
      fx: fx
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

    it 'persists entry_lane from signal metadata.meta_lane' do
      signal = CoindcxBot::Strategy::Signal.new(
        action: :open_long,
        pair: 'B-ETH_USDT',
        side: :long,
        stop_price: BigDecimal('1800'),
        reason: 'meta',
        metadata: { meta_lane: 'supertrend_profit', meta_priority: 1 }
      )

      coordinator.apply(signal, quantity: BigDecimal('0.01'), entry_price: BigDecimal('2000'))
      row = journal.open_positions.first
      expect(row[:entry_lane]).to eq('supertrend_profit')
    end

    it 'records meta_first_win cooldown meta after a paper close when strategy is meta_first_win' do
      meta_config = CoindcxBot::Config.new(
        minimal_bot_config(
          runtime: { dry_run: true, journal_path: journal_path },
          risk: { max_leverage: 3, per_trade_inr_min: 250, per_trade_inr_max: 500 },
          strategy: {
            name: 'meta_first_win',
            execution_resolution: '15m',
            higher_timeframe_resolution: '1h',
            meta_first_win: {
              cooldown_seconds_after_close: 45,
              children: [{ name: 'trend_continuation' }, { name: 'supertrend_profit' }]
            }
          },
          execution: { order_defaults: { leverage: 50, margin_currency_short_name: 'USDT', order_type: 'market_order' } }
        )
      )
      coord = described_class.new(
        broker: broker,
        journal: journal,
        config: meta_config,
        exposure_guard: CoindcxBot::Risk::ExposureGuard.new(config: meta_config),
        logger: nil,
        fx: fx
      )

      open_sig = CoindcxBot::Strategy::Signal.new(
        action: :open_long,
        pair: 'B-SOL_USDT',
        side: :long,
        stop_price: BigDecimal('90'),
        reason: 'test',
        metadata: { meta_lane: 'trend_continuation' }
      )
      coord.apply(open_sig, quantity: BigDecimal('0.01'), entry_price: BigDecimal('100'))
      jid = journal.open_positions.first[:id]

      close_sig = CoindcxBot::Strategy::Signal.new(
        action: :close,
        pair: 'B-SOL_USDT',
        side: :long,
        stop_price: nil,
        reason: 'tp',
        metadata: { position_id: jid }
      )
      coord.apply(close_sig, exit_price: BigDecimal('105'))

      raw = journal.meta_get("#{CoindcxBot::Strategy::MetaFirstWin::COOLDOWN_META_PREFIX}B-SOL_USDT")
      expect(raw).not_to be_nil
      expect(Float(raw)).to be > Time.now.to_f
    end

    it 'persists smc_setup_id on the journal row when signal metadata includes it' do
      signal = CoindcxBot::Strategy::Signal.new(
        action: :open_long,
        pair: 'B-SOL_USDT',
        side: :long,
        stop_price: BigDecimal('90'),
        reason: 'smc',
        metadata: { smc_setup_id: 'plan-9' }
      )

      coordinator.apply(signal, quantity: BigDecimal('0.01'), entry_price: BigDecimal('100'))

      row = journal.open_positions.first
      expect(row[:smc_setup_id]).to eq('plan-9')
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

    it 'sends a CoinDCX-shaped create payload on open (buy/sell, client_order_id, total_quantity)' do
      signal = CoindcxBot::Strategy::Signal.new(
        action: :open_long,
        pair: 'B-SOL_USDT',
        side: :long,
        stop_price: BigDecimal('90'),
        reason: 'test',
        metadata: {}
      )

      expect(orders).to receive(:create) do |args|
        o = args[:order]
        expect(o[:side] || o['side']).to eq('buy')
        expect(o[:order_type] || o['order_type']).to eq('market_order')
        expect(o[:total_quantity] || o['total_quantity']).to eq('0.01')
        cid = o[:client_order_id] || o['client_order_id']
        expect(cid.to_s).to start_with('coindcx-bot-')
        CoindcxBot::Gateways::Result.ok({})
      end

      expect(coordinator.apply(signal, quantity: BigDecimal('0.01'), entry_price: BigDecimal('100'))).to eq(:paper)
      expect(journal.open_positions.size).to eq(1)
    end

    it 'does not open a journal row and logs open_failed when the order gateway rejects the create' do
      signal = CoindcxBot::Strategy::Signal.new(
        action: :open_long,
        pair: 'B-SOL_USDT',
        side: :long,
        stop_price: BigDecimal('90'),
        reason: 'test',
        metadata: {}
      )

      allow(orders).to receive(:create).and_return(CoindcxBot::Gateways::Result.fail(:rejected, 'gateway error'))

      expect(coordinator.apply(signal, quantity: BigDecimal('0.01'), entry_price: BigDecimal('100'))).to eq(:failed)
      expect(journal.open_positions).to be_empty

      types = journal.recent_events(10).map { |e| e['type'] }
      expect(types).to include('open_failed')
      expect(types).not_to include('signal_open')
    end

    it 'logs signal_close with exchange_failed when the paper exchange lists no position' do
      jid = journal.insert_position(
        pair: 'B-ETH_USDT',
        side: 'long',
        entry_price: BigDecimal('2100'),
        quantity: BigDecimal('0.01'),
        stop_price: BigDecimal('2000'),
        trail_price: nil
      )

      allow(account).to receive(:list_positions).and_return(
        CoindcxBot::Gateways::Result.ok('positions' => [])
      )

      close_signal = CoindcxBot::Strategy::Signal.new(
        action: :close,
        pair: 'B-ETH_USDT',
        side: :long,
        stop_price: nil,
        reason: 'test',
        metadata: { position_id: jid }
      )

      coordinator.apply(close_signal, exit_price: BigDecimal('2100'))

      expect(journal.open_positions).to be_empty
      close_ev = journal.recent_events(10).find { |e| e['type'] == 'signal_close' }
      expect(close_ev).not_to be_nil
      payload = JSON.parse(close_ev['payload'], symbolize_names: true)
      expect(payload[:outcome]).to eq('exchange_failed')
      expect(payload[:pnl_booked]).to be false
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

  context 'when live mode and place_orders is disabled' do
    let(:config) do
      CoindcxBot::Config.new(
        minimal_bot_config(
          runtime: { dry_run: false, journal_path: journal_path, place_orders: false },
          risk: { max_leverage: 3, per_trade_inr_min: 250, per_trade_inr_max: 500 },
          execution: { order_defaults: { leverage: 50, margin_currency_short_name: 'USDT', order_type: 'market_order' } }
        )
      )
    end

    it 'does not call the order gateway on open and records open_failed' do
      signal = CoindcxBot::Strategy::Signal.new(
        action: :open_long,
        pair: 'B-SOL_USDT',
        side: :long,
        stop_price: BigDecimal('90'),
        reason: 'test',
        metadata: {}
      )

      expect(orders).not_to receive(:create)
      expect(coordinator.apply(signal, quantity: BigDecimal('0.01'), entry_price: BigDecimal('100'))).to eq(:failed)
      expect(journal.open_positions).to be_empty

      ev = journal.recent_events(10).find { |e| e['type'] == 'open_failed' }
      expect(ev).not_to be_nil
      payload = JSON.parse(ev['payload'], symbolize_names: true)
      expect(payload[:detail]).to eq('live_orders_disabled')
    end

    it 'does not call the account gateway on close and leaves the journal row open' do
      jid = journal.insert_position(
        pair: 'B-SOL_USDT',
        side: 'long',
        entry_price: BigDecimal('100'),
        quantity: BigDecimal('0.01'),
        stop_price: BigDecimal('90'),
        trail_price: nil
      )

      close_signal = CoindcxBot::Strategy::Signal.new(
        action: :close,
        pair: 'B-SOL_USDT',
        side: :long,
        stop_price: nil,
        reason: 'test',
        metadata: { position_id: jid }
      )

      expect(account).not_to receive(:list_positions)
      expect(coordinator.apply(close_signal, exit_price: BigDecimal('105'))).to eq(:failed)
      expect(journal.open_positions.size).to eq(1)

      ev = journal.recent_events(10).find { |e| e['type'] == 'signal_close' }
      expect(ev).not_to be_nil
      payload = JSON.parse(ev['payload'], symbolize_names: true)
      expect(payload[:outcome]).to eq('live_orders_disabled')
    end

    it 'skips exchange flatten and does not close journal rows for the pair' do
      journal.insert_position(
        pair: 'B-SOL_USDT',
        side: 'long',
        entry_price: BigDecimal('100'),
        quantity: BigDecimal('0.01'),
        stop_price: BigDecimal('90'),
        trail_price: nil
      )

      expect(account).not_to receive(:list_positions)
      coordinator.flatten_all(['B-SOL_USDT'], ltps: { 'B-SOL_USDT' => BigDecimal('102') })
      expect(journal.open_positions.size).to eq(1)
    end
  end
end
