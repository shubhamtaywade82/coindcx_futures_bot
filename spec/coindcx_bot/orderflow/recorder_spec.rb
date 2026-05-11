# frozen_string_literal: true

require 'json'

RSpec.describe CoindcxBot::Orderflow::Recorder do
  it 'writes snapshot lines including source' do
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        cfg = CoindcxBot::Config.new(
          minimal_bot_config(
            orderflow: { recorder: { enabled: true } }
          )
        )
        rec = described_class.new(config: cfg, logger: nil)
        rec.record_snapshot('B-SOL_USDT', [], [], source: :binance)
        rec.close
        path = Dir.glob(File.join(dir, 'data', 'orderflow_logs', '*.jsonl')).first
        expect(path).to be_truthy
        data = JSON.parse(File.read(path), symbolize_names: true)
        expect(data[:type]).to eq('snapshot')
        expect(data[:source]).to eq('binance')
      end
    end
  end

  it 'defaults snapshot source to coindcx when omitted' do
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        cfg = CoindcxBot::Config.new(
          minimal_bot_config(
            orderflow: { recorder: { enabled: true } }
          )
        )
        rec = described_class.new(config: cfg, logger: nil)
        rec.record_snapshot('B-SOL_USDT', [], [])
        rec.close
        path = Dir.glob(File.join(dir, 'data', 'orderflow_logs', '*.jsonl')).first
        data = JSON.parse(File.read(path), symbolize_names: true)
        expect(data[:source]).to eq('coindcx')
      end
    end
  end

  it 'enables recording when legacy orderflow.record_sessions is true' do
    cfg = CoindcxBot::Config.new(
      minimal_bot_config(
        orderflow: { record_sessions: true, recorder: { enabled: false } }
      )
    )
    expect(cfg.orderflow_recorder_enabled?).to eq(true)
  end
end
