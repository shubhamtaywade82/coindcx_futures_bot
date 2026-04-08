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
      CoindcxBot::Gateways::Result.ok({})
    end

    coordinator.apply(signal, quantity: BigDecimal('0.01'), entry_price: BigDecimal('100'))
  end
end
