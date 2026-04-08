# frozen_string_literal: true

RSpec.describe CoindcxBot::Risk::Manager do
  let(:journal_path) { Tempfile.new(['rj', '.sqlite3']).path }
  let(:journal) { CoindcxBot::Persistence::Journal.new(journal_path) }
  let(:config) { CoindcxBot::Config.new(minimal_bot_config) }
  let(:guard) { CoindcxBot::Risk::ExposureGuard.new(config: config) }

  subject(:manager) { described_class.new(config: config, journal: journal, exposure_guard: guard) }

  after do
    journal.close
    File.delete(journal_path) if File.exist?(journal_path)
  end

  it 'rejects new entries when kill switch is on' do
    journal.set_kill_switch(true)
    code, = manager.allow_new_entry?(open_positions: [], pair: 'B-SOL_USDT')
    expect(code).to eq(:reject)
  end

  it 'rejects when two positions are already open' do
    journal.insert_position(
      pair: 'B-SOL_USDT', side: 'long', entry_price: BigDecimal('1'), quantity: BigDecimal('1'),
      stop_price: BigDecimal('0.9'), trail_price: nil
    )
    journal.insert_position(
      pair: 'B-ETH_USDT', side: 'long', entry_price: BigDecimal('1'), quantity: BigDecimal('1'),
      stop_price: BigDecimal('0.9'), trail_price: nil
    )
    open = journal.open_positions
    code, reason = manager.allow_new_entry?(open_positions: open, pair: 'B-DOGE_USDT')
    expect(code).to eq(:reject)
    expect(reason).to eq('max_positions')
  end

  it 'flags daily loss breach' do
    journal.add_daily_pnl_inr(BigDecimal('-2000'))
    expect(manager.daily_loss_breached?).to be true
  end

  it 'sizes quantity from INR risk and stop distance' do
    qty = manager.size_quantity(entry_price: BigDecimal('100'), stop_price: BigDecimal('98'), side: :long)
    expect(qty).to be > 0
  end
end
