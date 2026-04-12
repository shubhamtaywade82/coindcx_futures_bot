# frozen_string_literal: true

require 'bigdecimal'
require 'securerandom'

RSpec.describe CoindcxBot::Persistence::Journal do
  let(:path) { File.join(Dir.tmpdir, "coindcx_journal_spec_#{SecureRandom.hex(8)}.sqlite3") }

  after do
    File.delete(path) if File.exist?(path)
  end

  it 'persists kill switch and daily pnl' do
    journal = described_class.new(path)
    expect(journal.kill_switch?).to be false
    journal.set_kill_switch(true)
    expect(journal.kill_switch?).to be true

    journal.add_daily_pnl_inr(BigDecimal('-10'))
    expect(journal.daily_pnl_inr).to eq(BigDecimal('-10'))
  end

  it 'initializes and updates pnl_current_day across calls' do
    journal = described_class.new(path)
    expect(journal.meta_get('pnl_current_day')).to be_nil
    journal.reset_daily_pnl_if_new_day!
    today = journal.daily_key
    expect(journal.meta_get('pnl_current_day')).to eq(today)
    journal.reset_daily_pnl_if_new_day!
    expect(journal.meta_get('pnl_current_day')).to eq(today)
  end

  it 'ignores close_position when id is nil' do
    journal = described_class.new(path)
    journal.insert_position(
      pair: 'B-SOL_USDT',
      side: 'long',
      entry_price: BigDecimal('100'),
      quantity: BigDecimal('0.1'),
      stop_price: BigDecimal('95'),
      trail_price: nil
    )
    expect { journal.close_position(nil) }.not_to(change { journal.open_positions.size })
  end

  it 'records open positions and closes them' do
    journal = described_class.new(path)
    id = journal.insert_position(
      pair: 'B-SOL_USDT',
      side: 'long',
      entry_price: BigDecimal('100'),
      quantity: BigDecimal('0.1'),
      stop_price: BigDecimal('95'),
      trail_price: nil
    )
    expect(journal.open_positions.size).to eq(1)
    journal.close_position(id)
    expect(journal.open_positions).to be_empty
  end

  it 'sums pnl_usdt from paper_realized events' do
    journal = described_class.new(path)
    journal.log_event('paper_realized', pnl_usdt: '2.5', pair: 'B-SOL_USDT')
    journal.log_event('paper_realized', pnl_usdt: '1.0', pair: 'B-ETH_USDT')
    expect(journal.sum_paper_realized_pnl_usdt).to eq(BigDecimal('3.5'))
  end

  it 'updates entry_price for an open position' do
    journal = described_class.new(path)
    id = journal.insert_position(
      pair: 'B-SOL_USDT',
      side: 'long',
      entry_price: BigDecimal('100'),
      quantity: BigDecimal('0.1'),
      stop_price: BigDecimal('95'),
      trail_price: nil
    )
    journal.update_position_entry_price(id, BigDecimal('100.05'))
    row = journal.open_positions.first
    expect(BigDecimal(row[:entry_price])).to eq(BigDecimal('100.05'))
  end

  it 'migrates peak_unrealized_usdt and bumps monotonically' do
    journal = described_class.new(path)
    id = journal.insert_position(
      pair: 'B-SOL_USDT',
      side: 'long',
      entry_price: BigDecimal('100'),
      quantity: BigDecimal('0.1'),
      stop_price: BigDecimal('95'),
      trail_price: nil
    )
    expect(journal.bump_peak_unrealized_usdt(id, BigDecimal('-2'))).to eq(BigDecimal('-2'))
    expect(journal.bump_peak_unrealized_usdt(id, BigDecimal('5'))).to eq(BigDecimal('5'))
    expect(journal.bump_peak_unrealized_usdt(id, BigDecimal('3'))).to eq(BigDecimal('5'))

    row = journal.open_positions.first
    expect(BigDecimal(row[:peak_unrealized_usdt])).to eq(BigDecimal('5'))
  end

  it 'returns nil from bump_peak_unrealized_usdt when position is missing' do
    journal = described_class.new(path)
    expect(journal.bump_peak_unrealized_usdt(99_999, BigDecimal('1'))).to be_nil
  end

  it 'stores initial_stop_price and leaves it unchanged when stop is trailed' do
    journal = described_class.new(path)
    id = journal.insert_position(
      pair: 'B-SOL_USDT',
      side: 'long',
      entry_price: BigDecimal('100'),
      quantity: BigDecimal('0.1'),
      stop_price: BigDecimal('90'),
      trail_price: nil,
      initial_stop_price: BigDecimal('90')
    )
    journal.update_position_stop(id, BigDecimal('98'))
    row = journal.open_positions.first
    expect(BigDecimal(row[:stop_price])).to eq(BigDecimal('98'))
    expect(BigDecimal(row[:initial_stop_price])).to eq(BigDecimal('90'))
  end

  it 'persists smc_trade_setups and detects open position by smc_setup_id' do
    journal = described_class.new(path)
    journal.smc_setup_insert_or_update(
      setup_id: 's1',
      pair: 'B-SOL_USDT',
      state: 'pending_sweep',
      payload: { schema_version: 1, setup_id: 's1', pair: 'B-SOL_USDT', direction: 'long',
                 conditions: { sweep_zone: { min: 1, max: 2 }, entry_zone: { min: 1, max: 2 } },
                 execution: { sl: 1 } },
      eval_state: {}
    )
    expect(journal.smc_setup_load_active.size).to eq(1)
    expect(journal.smc_setup_exists?('s1')).to be(true)

    journal.insert_position(
      pair: 'B-SOL_USDT',
      side: 'long',
      entry_price: BigDecimal('100'),
      quantity: BigDecimal('0.1'),
      stop_price: BigDecimal('95'),
      trail_price: nil,
      smc_setup_id: 's1'
    )
    expect(journal.open_position_with_smc_setup?('s1')).to be(true)
  end

  it 'counts and lists recent smc_trade_setups regardless of state' do
    journal = described_class.new(path)
    journal.smc_setup_insert_or_update(
      setup_id: 'z1',
      pair: 'B-SOL_USDT',
      state: 'completed',
      payload: { schema_version: 1, setup_id: 'z1', pair: 'B-SOL_USDT', direction: 'long',
                 conditions: { sweep_zone: { min: 1, max: 2 }, entry_zone: { min: 1, max: 2 } },
                 execution: { sl: 1 } },
      eval_state: {}
    )
    expect(journal.smc_setup_count_all).to eq(1)
    expect(journal.smc_setup_load_active).to be_empty
    recent = journal.smc_setup_list_recent(5)
    expect(recent.first[:setup_id]).to eq('z1')
    expect(recent.first[:state]).to eq('completed')
  end
end
