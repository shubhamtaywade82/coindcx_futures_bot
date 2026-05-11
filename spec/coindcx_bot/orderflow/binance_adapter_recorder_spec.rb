# frozen_string_literal: true

require 'bigdecimal'

RSpec.describe CoindcxBot::Orderflow::BinanceAdapter do
  let(:engine) { instance_double(CoindcxBot::Orderflow::Engine, on_trade: nil, on_book_update: nil) }
  let(:recorder) { instance_double(CoindcxBot::Orderflow::Recorder, record_trade: nil, record_snapshot: nil) }
  let(:manager) { double('ResyncManager') }
  let(:trade_ws) do
    Class.new do
      attr_accessor :handler
      def on_trade(&block)
        @handler = block
        self
      end

      def connect
        self
      end

      def disconnect; end
    end.new
  end

  it 'records binance trades when a recorder is supplied' do
    allow(manager).to receive(:after_apply=)
    book = CoindcxBot::Exchanges::Binance::LocalBook.new
    adapter = described_class.new(
      engine: engine,
      book: book,
      manager: manager,
      trade_ws: trade_ws,
      coindcx_pair: 'B-SOL_USDT',
      recorder: recorder
    )
    allow(manager).to receive(:after_apply=)
    t = { pair: 'B-SOL_USDT', price: BigDecimal('1'), size: BigDecimal('2'), side: :buy, ts: 9, source: :binance }
    trade_ws.handler.call(t)
    expect(recorder).to have_received(:record_trade).with(hash_including(source: :binance, pair: 'B-SOL_USDT'))
    expect(engine).to have_received(:on_trade).with(t)
  end
end
