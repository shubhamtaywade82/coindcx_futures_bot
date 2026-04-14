# frozen_string_literal: true

RSpec.describe CoindcxBot::SmcSetup::TradeSetupStore do
  let(:path) { Tempfile.new(['smc_store', '.sqlite3']).path }
  let(:journal) { CoindcxBot::Persistence::Journal.new(path) }

  after do
    journal.close
    File.delete(path) if File.exist?(path)
  end

  def payload(id)
    {
      schema_version: 1,
      setup_id: id,
      pair: 'B-SOL_USDT',
      direction: 'long',
      conditions: {
        sweep_zone: { min: 1, max: 200 },
        entry_zone: { min: 50, max: 60 },
        confirmation_required: []
      },
      execution: { sl: 0.5 }
    }
  end

  it 'upserts, reloads, and supersedes oldest active row when a new setup_id exceeds max per pair' do
    store = described_class.new(journal: journal, max_active_setups_per_pair: 2)
    store.upsert_from_hash!(payload('a'))
    store.upsert_from_hash!(payload('b'))
    store.reload!
    expect(store.records_for_pair('B-SOL_USDT').size).to eq(2)

    store.upsert_from_hash!(payload('c'))
    expect(journal.smc_setup_get_row('a')[:state]).to eq('invalidated')
    expect(journal.smc_setup_get_row('b')[:state]).to eq('pending_sweep')
    expect(journal.smc_setup_get_row('c')[:state]).to eq('pending_sweep')
    store.reload!
    expect(store.records_for_pair('B-SOL_USDT').map(&:setup_id).sort).to eq(%w[b c])
  end

  it 'raises when at capacity and every active setup is tied to an open position' do
    store = described_class.new(journal: journal, max_active_setups_per_pair: 2)
    store.upsert_from_hash!(payload('a'))
    store.upsert_from_hash!(payload('b'))
    journal.insert_position(
      pair: 'B-SOL_USDT',
      side: 'long',
      entry_price: BigDecimal('100'),
      quantity: BigDecimal('0.1'),
      stop_price: BigDecimal('90'),
      trail_price: nil,
      smc_setup_id: 'a'
    )
    journal.insert_position(
      pair: 'B-SOL_USDT',
      side: 'short',
      entry_price: BigDecimal('100'),
      quantity: BigDecimal('0.1'),
      stop_price: BigDecimal('110'),
      trail_price: nil,
      smc_setup_id: 'b'
    )
    expect do
      store.upsert_from_hash!(payload('c'))
    end.to raise_error(CoindcxBot::SmcSetup::Validator::ValidationError, /open positions/)
  end

  it 'reports pair_has_actionable? for non-terminal states' do
    store = described_class.new(journal: journal, max_active_setups_per_pair: 3)
    store.upsert_from_hash!(payload('x'))
    store.reload!
    expect(store.pair_has_actionable?('B-SOL_USDT')).to be(true)
  end
end
