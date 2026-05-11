# frozen_string_literal: true

require 'bigdecimal'
require 'json'

RSpec.describe CoindcxBot::Exchanges::Binance::MultiplexedBookTickerWs do
  let(:fake_transport_class) do
    Class.new do
      attr_reader :last_on_message
      def connect(url:, on_message:, on_open:, on_close:, on_error:)
        @last_on_message = on_message
        on_open.call
        self
      end

      def push(raw)
        @last_on_message.call(raw)
      end

      def close; end
    end
  end

  let(:transport) { fake_transport_class.new }

  it 'routes bookTicker quotes per stream' do
    q1 = nil
    mux = described_class.new(
      symbol_map: { 'BTCUSDT' => 'B-BTC_USDT' },
      transport: transport
    )
    mux.stream_for('BTCUSDT').on_quote { |q| q1 = q }
    mux.stream_for('BTCUSDT').connect

    transport.push(JSON.generate(
      'stream' => 'btcusdt@bookTicker',
      'data' => { 'e' => 'bookTicker', 's' => 'BTCUSDT', 'b' => '99', 'a' => '101', 'E' => 50 }
    ))

    expect(q1[:pair]).to eq('B-BTC_USDT')
    expect(q1[:best_bid]).to eq(BigDecimal('99'))
    expect(q1[:source]).to eq(:binance)
  end
end
