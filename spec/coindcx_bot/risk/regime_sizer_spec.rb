# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'
require_relative '../../../lib/coindcx_bot/config'
require_relative '../../../lib/coindcx_bot/risk/regime_sizer'
require_relative '../../../lib/coindcx_bot/persistence/journal'

RSpec.describe CoindcxBot::Risk::RegimeSizer do
  let(:journal_path) { File.join(Dir.pwd, 'tmp_regime_sizer_journal.sqlite3') }

  after do
    FileUtils.rm_f(journal_path)
  end

  it 'returns 0 when daily loss exceeds halt threshold vs capital' do
    raw = {
      pairs: ['B-X_USDT'],
      margin_currency_short_name: 'USDT',
      capital_inr: 100_000,
      risk: {},
      strategy: {},
      execution: { order_defaults: {} },
      runtime: { journal_path: journal_path },
      regime: {
        enabled: true,
        risk: {
          enabled: true,
          daily_dd_halt_pct_of_capital: 2.0,
          daily_dd_reduce_pct_of_capital: 1.0
        }
      }
    }
    config = CoindcxBot::Config.new(raw)
    j = CoindcxBot::Persistence::Journal.new(config.journal_path)
    allow(j).to receive(:daily_pnl_inr).and_return(BigDecimal('-2500')) # 2.5%

    sizer = described_class.new(config)
    expect(sizer.multiplier_for(j)).to eq(BigDecimal('0'))
  end

  it 'returns reduce factor between reduce and halt' do
    raw = {
      pairs: ['B-X_USDT'],
      margin_currency_short_name: 'USDT',
      capital_inr: 100_000,
      risk: {},
      strategy: {},
      execution: { order_defaults: {} },
      runtime: { journal_path: journal_path },
      regime: {
        enabled: true,
        risk: {
          enabled: true,
          daily_dd_halt_pct_of_capital: 3.0,
          daily_dd_reduce_pct_of_capital: 1.5,
          size_reduce_factor: 0.5
        }
      }
    }
    config = CoindcxBot::Config.new(raw)
    j = CoindcxBot::Persistence::Journal.new(config.journal_path)
    allow(j).to receive(:daily_pnl_inr).and_return(BigDecimal('-2000')) # 2%

    sizer = described_class.new(config)
    expect(sizer.multiplier_for(j)).to eq(BigDecimal('0.5'))
  end
end
