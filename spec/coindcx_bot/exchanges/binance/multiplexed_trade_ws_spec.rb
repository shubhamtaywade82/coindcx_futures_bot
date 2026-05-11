# frozen_string_literal: true

require 'json'

RSpec.describe CoindcxBot::Exchanges::Binance::MultiplexedTradeWs do
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

  it 'routes aggTrade to the feed for that symbol' do
    sol = nil
    eth = nil
    mux = described_class.new(
      symbol_map: { 'SOLUSDT' => 'B-SOL_USDT', 'ETHUSDT' => 'B-ETH_USDT' },
      transport: transport
    )
    mux.stream_for('SOLUSDT').on_trade { |t| sol = t }
    mux.stream_for('ETHUSDT').on_trade { |t| eth = t }
    mux.stream_for('SOLUSDT').connect
    mux.stream_for('ETHUSDT').connect

    transport.push(JSON.generate(
      'stream' => 'solusdt@aggTrade',
      'data' => { 'e' => 'aggTrade', 's' => 'SOLUSDT', 'p' => '10', 'q' => '2', 'm' => false, 'T' => 100 }
    ))
    transport.push(JSON.generate(
      'stream' => 'ethusdt@aggTrade',
      'data' => { 'e' => 'aggTrade', 's' => 'ETHUSDT', 'p' => '1', 'q' => '1', 'm' => true, 'T' => 200 }
    ))

    expect(sol[:pair]).to eq('B-SOL_USDT')
    expect(sol[:source]).to eq(:binance)
    expect(eth[:pair]).to eq('B-ETH_USDT')
    expect(eth[:side]).to eq(:sell)
  end
end
