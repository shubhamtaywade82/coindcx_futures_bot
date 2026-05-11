# frozen_string_literal: true

require 'bigdecimal'
require 'json'

RSpec.describe CoindcxBot::Exchanges::Binance::TradeWs do
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
      symbol: 'SOLUSDT',
      coindcx_pair: 'B-SOL_USDT',
      transport: fake_transport
    )
  end

  it 'yields normalized trades with sell aggressor when m is true' do
    out = nil
    ws.on_trade { |t| out = t }
    ws.connect
    payload = {
      'data' => {
        'e' => 'aggTrade',
        'p' => '150.25',
        'q' => '0.4',
        'm' => true,
        'T' => 1_700_000_000_000
      }
    }
    fake_transport.push(JSON.generate(payload))

    expect(out[:pair]).to eq('B-SOL_USDT')
    expect(out[:price]).to eq(BigDecimal('150.25'))
    expect(out[:size]).to eq(BigDecimal('0.4'))
    expect(out[:side]).to eq(:sell)
    expect(out[:ts]).to eq(1_700_000_000_000)
    expect(out[:source]).to eq(:binance)
  end

  it 'yields buy aggressor when m is false' do
    out = nil
    ws.on_trade { |t| out = t }
    ws.connect
    fake_transport.push(JSON.generate('data' => { 'e' => 'aggTrade', 'p' => '1', 'q' => '2', 'm' => false, 'T' => 99 }))

    expect(out[:side]).to eq(:buy)
  end
end
