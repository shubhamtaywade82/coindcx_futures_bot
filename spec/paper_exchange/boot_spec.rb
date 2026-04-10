# frozen_string_literal: true

require 'spec_helper'
require 'coindcx_bot/paper_exchange'

RSpec.describe CoindcxBot::PaperExchange::Boot do
  let(:path) { File.join(Dir.tmpdir, "pe_boot_#{Process.pid}_#{rand(1_000_000)}.sqlite3") }
  let(:store) { CoindcxBot::PaperExchange::Store.new(path) }

  after { FileUtils.rm_f(path) }

  it 'updates api_secret when the same key is re-seeded with a new secret' do
    described_class.ensure_seed!(
      store,
      api_key: 'k1',
      api_secret: 'old-secret',
      seed_spot_usdt: '0',
      seed_futures_usdt: '1'
    )
    row = store.db.get_first_row('SELECT api_secret FROM pe_api_keys WHERE api_key = ?', ['k1'])
    expect(row['api_secret']).to eq('old-secret')

    described_class.ensure_seed!(
      store,
      api_key: 'k1',
      api_secret: 'new-secret',
      seed_spot_usdt: '0',
      seed_futures_usdt: '1'
    )
    row = store.db.get_first_row('SELECT api_secret FROM pe_api_keys WHERE api_key = ?', ['k1'])
    expect(row['api_secret']).to eq('new-secret')
  end
end
