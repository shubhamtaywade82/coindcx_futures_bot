# frozen_string_literal: true

require 'json'
require 'tempfile'

RSpec.describe CoindcxBot::Orderflow::Replayer do
  let(:bus) { CoindcxBot::Core::EventBus.new }
  let(:config) do
    CoindcxBot::Config.new(
      minimal_bot_config(
        orderflow: {
          enabled: true,
          imbalance: { dedup: { enabled: false } },
          walls: { dedup: { enabled: false } }
        }
      )
    )
  end
  let(:engine) { CoindcxBot::Orderflow::Engine.new(bus: bus, config: config, logger: nil) }

  it 'replays book updates with explicit source and defaults missing source to coindcx' do
    book_calls = []
    allow(engine).to receive(:on_book_update) do |**kw|
      book_calls << kw
    end
    Tempfile.create(%w[replay .jsonl]) do |f|
      f.puts(JSON.generate(type: :snapshot, pair: 'B-SOL_USDT', bids: [], asks: [], source: 'binance'))
      f.puts(JSON.generate(type: :snapshot, pair: 'B-SOL_USDT', bids: [], asks: []))
      f.close
      described_class.new(engine: engine).replay_file(f.path)
    end
    expect(book_calls[0][:source]).to eq(:binance)
    expect(book_calls[1][:source]).to eq(:coindcx)
  end

  it 'filters lines with only_source' do
    trades = []
    allow(engine).to receive(:on_trade) { |t| trades << t }
    allow(engine).to receive(:on_book_update)
    Tempfile.create(%w[replay .jsonl]) do |f|
      f.puts(JSON.generate(type: :trade, pair: 'B-SOL_USDT', price: '1', size: '1', side: 'buy', ts: 1, source: 'coindcx'))
      f.puts(JSON.generate(type: :trade, pair: 'B-SOL_USDT', price: '2', size: '1', side: 'sell', ts: 2, source: 'binance'))
      f.close
      described_class.new(engine: engine, only_source: :binance).replay_file(f.path)
    end
    expect(trades.size).to eq(1)
    expect(trades.first[:price].to_s).to eq('2')
  end
end
