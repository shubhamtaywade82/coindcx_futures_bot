# frozen_string_literal: true

RSpec.describe CoindcxBot::PaperStatus do
  let(:journal_path) { Tempfile.new(['paper_status', '.sqlite3']).path }
  let(:config) do
    CoindcxBot::Config.new(minimal_bot_config(runtime: { journal_path: journal_path, dry_run: true }))
  end
  let(:output) { StringIO.new }

  after do
    File.delete(journal_path) if File.exist?(journal_path)
  end

  describe '#print' do
    it 'prints journal path, mode, PnL, and open positions' do
      journal = CoindcxBot::Persistence::Journal.new(journal_path)
      journal.insert_position(
        pair: 'B-SOL_USDT',
        side: 'long',
        entry_price: BigDecimal('100'),
        quantity: BigDecimal('0.1'),
        stop_price: BigDecimal('95'),
        trail_price: nil
      )
      journal.add_daily_pnl_inr(BigDecimal('12.5'))
      journal.log_event(
        'paper_realized',
        position_id: 1,
        pair: 'B-SOL_USDT',
        pnl_usdt: '1',
        pnl_inr: '83',
        exit_price: '110'
      )

      described_class.new(config: config, journal: journal, output: output).print
      journal.close

      text = output.string
      expect(text).to include(journal_path)
      expect(text).to include('paper')
      expect(text).to include('12.5')
      expect(text).to include('B-SOL_USDT')
      expect(text).to include('long')
      expect(text).to include('paper_realized')
      expect(text).to include('83')
    end
  end
end
