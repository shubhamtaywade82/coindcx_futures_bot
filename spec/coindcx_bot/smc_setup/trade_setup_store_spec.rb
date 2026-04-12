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

  it 'upserts, reloads, and enforces max_active_setups_per_pair' do
    store = described_class.new(journal: journal, max_active_setups_per_pair: 2)
    store.upsert_from_hash!(payload('a'))
    store.upsert_from_hash!(payload('b'))
    store.reload!
    expect(store.records_for_pair('B-SOL_USDT').size).to eq(2)

    expect do
      store.upsert_from_hash!(payload('c'))
    end.to raise_error(CoindcxBot::SmcSetup::Validator::ValidationError, /max_active/)
  end

  it 'reports pair_has_actionable? for non-terminal states' do
    store = described_class.new(journal: journal, max_active_setups_per_pair: 3)
    store.upsert_from_hash!(payload('x'))
    store.reload!
    expect(store.pair_has_actionable?('B-SOL_USDT')).to be(true)
  end
end
