# frozen_string_literal: true

require 'fileutils'
require 'spec_helper'
require 'coindcx_bot/paper_exchange'

RSpec.describe CoindcxBot::PaperExchange::Ledger do
  let(:path) { File.join(Dir.tmpdir, "pe_ledger_#{Process.pid}_#{rand(1_000_000)}.sqlite3") }
  let(:store) { CoindcxBot::PaperExchange::Store.new(path) }
  let(:ledger) { described_class.new(store) }

  after { FileUtils.rm_f(path) }

  describe '#post_batch!' do
    it 'rejects imbalanced batches' do
      ledger.ensure_default_accounts!(1)
      expect do
        ledger.post_batch!(
          user_id: 1,
          lines: {
            described_class::ACCOUNT_FUTURES_AVAILABLE => BigDecimal('10')
          }
        )
      end.to raise_error(CoindcxBot::PaperExchange::Ledger::InvariantError)
    end

    it 'posts a balanced seed-style batch' do
      ledger.post_batch!(
        user_id: 1,
        external_ref: 't_seed',
        memo: 'test',
        lines: {
          described_class::ACCOUNT_SPOT_AVAILABLE => BigDecimal('100'),
          described_class::ACCOUNT_FUTURES_AVAILABLE => BigDecimal('50'),
          described_class::ACCOUNT_EQUITY => BigDecimal('-150')
        }
      )

      expect(ledger.balance_for(1, described_class::ACCOUNT_FUTURES_AVAILABLE)).to eq(BigDecimal('50'))
    end
  end
end
