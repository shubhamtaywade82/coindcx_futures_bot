# frozen_string_literal: true

require 'bigdecimal'
require 'json'

RSpec.describe CoindcxBot::Exchanges::Binance::MultiplexedDepthWs do
  let(:fake_transport_class) do
    Class.new do
      attr_reader :url_connected, :last_on_message
      def connect(url:, on_message:, on_open:, on_close:, on_error:)
        @url_connected = url
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

  def depth_envelope(stream:, first_u:, final_u:, prev_u: nil)
    {
      'stream' => stream,
      'data' => {
        'e' => 'depthUpdate',
        's' => stream.split('@').first.upcase,
        'U' => first_u,
        'u' => final_u,
        'pu' => prev_u,
        'E' => 1,
        'T' => 2,
        'b' => [['100', '1.0']],
        'a' => []
      }
    }
  end

  it 'routes combined-stream envelopes to the matching symbol feed' do
    btc_ev = nil
    eth_ev = nil
    mux = described_class.new(
      symbols: %w[BTCUSDT ETHUSDT],
      max_symbols_per_socket: 25,
      transport: transport
    )
    mux.stream_for('BTCUSDT').on_event { |e| btc_ev = e }
    mux.stream_for('ETHUSDT').on_event { |e| eth_ev = e }
    mux.stream_for('BTCUSDT').connect
    mux.stream_for('ETHUSDT').connect

    transport.push(JSON.generate(depth_envelope(stream: 'btcusdt@depth@100ms', first_u: 1, final_u: 2, prev_u: nil)))
    transport.push(JSON.generate(depth_envelope(stream: 'ethusdt@depth@100ms', first_u: 10, final_u: 11, prev_u: 9)))

    expect(btc_ev&.final_u).to eq(2)
    expect(eth_ev&.final_u).to eq(11)
    expect(transport.url_connected).to include('btcusdt@depth@100ms')
    expect(transport.url_connected).to include('ethusdt@depth@100ms')
  end

  it 'partitions into multiple sockets when symbol count exceeds max_symbols_per_socket' do
    mux = described_class.new(
      symbols: %w[AAAUSDT BBBUSDT CCCUSDT],
      max_symbols_per_socket: 2,
      transport: transport
    )
    urls = mux.partition_urls
    expect(urls.size).to eq(2)
    expect(urls[0]).to include('aaausdt@depth@100ms')
    expect(urls[0]).to include('bbbusdt@depth@100ms')
    expect(urls[1]).to include('cccusdt@depth@100ms')
  end

  it 'invokes on_error when inner payload cannot be built' do
    err = nil
    mux = described_class.new(symbols: %w[BTCUSDT], transport: transport)
    mux.stream_for('BTCUSDT').on_error { |e| err = e }
    mux.stream_for('BTCUSDT').connect

    bad = {
      'stream' => 'btcusdt@depth@100ms',
      'data' => {
        'e' => 'depthUpdate',
        's' => 'BTCUSDT',
        'U' => 'x',
        'u' => 2,
        'b' => [],
        'a' => []
      }
    }
    transport.push(JSON.generate(bad))

    expect(err).to be_a(StandardError)
  end
end
