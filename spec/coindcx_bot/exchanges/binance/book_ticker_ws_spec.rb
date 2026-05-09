# frozen_string_literal: true

require 'bigdecimal'
require 'json'

RSpec.describe CoindcxBot::Exchanges::Binance::BookTickerWs do
  let(:fake_transport) do
    Class.new do
      attr_reader :on_message
      def connect(url:, on_message:, on_open:, on_close:, on_error:)
        @on_message = on_message
        on_open.call
        self
      end

      def push(raw)
        @on_message.call(raw)
      end

      def close; end
    end.new
  end

  let(:ws) do
    described_class.new(
      symbol: 'BTCUSDT',
      coindcx_pair: 'B-BTC_USDT',
      transport: fake_transport
    )
  end

  it 'yields best bid/ask with source :binance' do
    out = nil
    ws.on_quote { |q| out = q }
    ws.connect
    fake_transport.push(
      JSON.generate(
        'data' => {
          'e' => 'bookTicker',
          'b' => '50000.5',
          'a' => '50001.0',
          'E' => 1_234_567_890
        }
      )
    )

    expect(out[:pair]).to eq('B-BTC_USDT')
    expect(out[:best_bid]).to eq(BigDecimal('50000.5'))
    expect(out[:best_ask]).to eq(BigDecimal('50001.0'))
    expect(out[:ts]).to eq(1_234_567_890)
    expect(out[:source]).to eq(:binance)
  end
end
