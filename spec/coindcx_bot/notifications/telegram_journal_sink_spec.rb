# frozen_string_literal: true

RSpec.describe CoindcxBot::Notifications::TelegramJournalSink do
  let(:logger) { instance_double(Logger, warn: nil, info: nil) }

  let(:fake_http) do
    Class.new do
      def initialize
        @calls = []
        @mutex = Mutex.new
      end

      attr_reader :calls

      def post_message(token:, chat_id:, text:)
        @mutex.synchronize { @calls << [token, chat_id, text] }
      end
    end.new
  end

  def build_sink(ops_chat: '', ops_types: %w[open_failed])
    described_class.new(
      main_token: 'main-token',
      main_chat: '111',
      ops_token: 'ops-token',
      ops_chat: ops_chat,
      ops_types: ops_types,
      logger: logger,
      http: fake_http
    )
  end

  it 'posts once to the main chat with human-readable body' do
    sink = build_sink(ops_chat: '')
    sink.deliver(
      'signal_open',
      { 'pair' => 'B-SOL_USDT', 'action' => 'open_long', 'reason' => 'r', 'leverage' => 5 }
    )
    sleep 0.05
    expect(fake_http.calls.size).to eq(1)
    expect(fake_http.calls.first[0]).to eq('main-token')
    expect(fake_http.calls.first[1]).to eq('111')
    body = fake_http.calls.first[2]
    expect(body).to include('signal_open')
    expect(body).to include('Open LONG · B-SOL_USDT')
    expect(body).not_to include('{"type"')
  end

  it 'duplicates configured types to the ops chat when distinct' do
    sink = build_sink(ops_chat: '222', ops_types: %w[open_failed])
    sink.deliver('open_failed', { pair: 'B-ETH_USDT' })
    sleep 0.08
    expect(fake_http.calls.size).to eq(2)
    chats = fake_http.calls.map { |c| c[1] }.sort
    expect(chats).to eq(%w[111 222])
  end

  it 'does not duplicate to ops when chat matches main' do
    sink = build_sink(ops_chat: '111', ops_types: %w[open_failed])
    sink.deliver('open_failed', {})
    sleep 0.05
    expect(fake_http.calls.size).to eq(1)
  end

  describe '.build_if_configured' do
    it 'returns nil when telegram is not configured' do
      cfg = CoindcxBot::Config.new(minimal_bot_config)
      expect(described_class.build_if_configured(config: cfg, logger: nil)).to be_nil
    end
  end

  it 'swallows HTTP errors from the worker thread' do
    boom = Class.new do
      def post_message(*)
        raise 'network down'
      end
    end.new
    sink = described_class.new(
      main_token: 't',
      main_chat: '1',
      ops_token: 't',
      ops_chat: '',
      ops_types: [],
      logger: logger,
      http: boom
    )
    expect { sink.deliver('signal_open', {}); sleep 0.03 }.not_to raise_error
  end
end
