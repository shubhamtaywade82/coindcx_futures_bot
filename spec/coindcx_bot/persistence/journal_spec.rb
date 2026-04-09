# frozen_string_literal: true

RSpec.describe CoindcxBot::Persistence::Journal do
  let(:path) { Tempfile.new(['j', '.sqlite3']).path }

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
end
