# frozen_string_literal: true

require 'securerandom'

RSpec.describe CoindcxBot::Execution::Coordinator, 'bracket orders & trail sync' do
  let(:journal_path) { File.join(Dir.tmpdir, "coindcx_coord_bracket_#{SecureRandom.hex(12)}.sqlite3") }
  let(:journal) { CoindcxBot::Persistence::Journal.new(journal_path) }
  let(:paper_store_path) { File.join(Dir.tmpdir, "coindcx_coord_bracket_paper_#{SecureRandom.hex(12)}.sqlite3") }
  let(:paper_store) { CoindcxBot::Persistence::PaperStore.new(paper_store_path) }
  let(:fill_engine) { CoindcxBot::Execution::FillEngine.new(slippage_bps: 0, fee_bps: 0) }

  let(:config) do
    CoindcxBot::Config.new(
      minimal_bot_config(
        runtime: { dry_run: true, journal_path: journal_path },
        risk: { max_leverage: 3, per_trade_inr_min: 250, per_trade_inr_max: 500 },
        execution: { order_defaults: { leverage: 3, margin_currency_short_name: 'USDT' } },
        paper: { take_profit_r_multiple: 3 }
      )
    )
  end

  let(:guard) { CoindcxBot::Risk::ExposureGuard.new(config: config) }
  let(:fx) { instance_double(CoindcxBot::Fx::UsdtInrRate, inr_per_usdt: config.inr_per_usdt) }
  let(:broker) { CoindcxBot::Execution::PaperBroker.new(store: paper_store, fill_engine: fill_engine, logger: nil) }

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
    paper_store.close
    File.delete(journal_path) if File.exist?(journal_path)
    File.delete(paper_store_path) if File.exist?(paper_store_path)
  end

  describe 'bracket order placement on open' do
    it 'places a bracket order with SL and TP via the paper broker' do
      signal = CoindcxBot::Strategy::Signal.new(
        action: :open_long,
        pair: 'B-SOL_USDT',
        side: :long,
        stop_price: BigDecimal('90'),
        reason: 'test',
        metadata: {}
      )

      result = coordinator.apply(signal, quantity: BigDecimal('1'), entry_price: BigDecimal('100'))
      expect(result).to eq(:paper)

      # Broker should have working SL and TP orders
      expect(broker.order_book.size).to eq(2)

      # Journal should have the position
      pos = journal.open_positions
      expect(pos.size).to eq(1)
      expect(pos.first[:pair]).to eq('B-SOL_USDT')

      # TP should be at 3R = 100 + 3*(100-90) = 130
      group = paper_store.find_active_group_for_pair('B-SOL_USDT')
      tp_order = paper_store.find_order(group[:tp_order_id])
      expect(BigDecimal(tp_order[:stop_price])).to eq(BigDecimal('130'))
    end

    it 'places bracket for short with correct TP' do
      signal = CoindcxBot::Strategy::Signal.new(
        action: :open_short,
        pair: 'B-ETH_USDT',
        side: :short,
        stop_price: BigDecimal('2100'),
        reason: 'test',
        metadata: {}
      )

      coordinator.apply(signal, quantity: BigDecimal('0.1'), entry_price: BigDecimal('2000'))

      group = paper_store.find_active_group_for_pair('B-ETH_USDT')
      expect(group).not_to be_nil

      # TP for short = 2000 - 3*(2100-2000) = 2000 - 300 = 1700
      tp_order = paper_store.find_order(group[:tp_order_id])
      expect(BigDecimal(tp_order[:stop_price])).to eq(BigDecimal('1700'))
    end
  end

  describe 'trail stop sync to broker' do
    it 'updates broker working SL when strategy trails' do
      open_signal = CoindcxBot::Strategy::Signal.new(
        action: :open_long,
        pair: 'B-SOL_USDT',
        side: :long,
        stop_price: BigDecimal('90'),
        reason: 'test',
        metadata: {}
      )
      coordinator.apply(open_signal, quantity: BigDecimal('1'), entry_price: BigDecimal('100'))

      id = journal.open_positions.first[:id]

      trail_signal = CoindcxBot::Strategy::Signal.new(
        action: :trail,
        pair: 'B-SOL_USDT',
        side: :long,
        stop_price: BigDecimal('105'),
        reason: 'atr_trail',
        metadata: { position_id: id }
      )

      coordinator.apply(trail_signal)

      # Journal should have updated stop
      expect(BigDecimal(journal.open_positions.first[:stop_price])).to eq(BigDecimal('105'))

      # Broker's working SL order should also be updated
      group = paper_store.find_active_group_for_pair('B-SOL_USDT')
      sl_order = broker.order_book.find(group[:sl_order_id])
      expect(sl_order.stop_price).to eq(BigDecimal('105'))
    end
  end

  describe '#handle_broker_exit' do
    it 'syncs journal and books INR PnL when broker fills a working SL' do
      open_signal = CoindcxBot::Strategy::Signal.new(
        action: :open_long,
        pair: 'B-SOL_USDT',
        side: :long,
        stop_price: BigDecimal('90'),
        reason: 'test',
        metadata: {}
      )
      coordinator.apply(open_signal, quantity: BigDecimal('1'), entry_price: BigDecimal('100'))

      expect(journal.open_positions.size).to eq(1)

      # Simulate broker exit (as engine would call)
      coordinator.handle_broker_exit(
        pair: 'B-SOL_USDT',
        realized_pnl_usdt: BigDecimal('-10'),
        fill_price: BigDecimal('90'),
        position_id: 1,
        trigger: :stop_loss
      )

      expect(journal.open_positions).to be_empty
      expect(journal.daily_pnl_inr).to eq(BigDecimal('-10') * config.inr_per_usdt)
    end
  end
end
