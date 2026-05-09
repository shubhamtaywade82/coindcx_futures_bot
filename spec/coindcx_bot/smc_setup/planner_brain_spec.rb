# frozen_string_literal: true

RSpec.describe CoindcxBot::SmcSetup::PlannerBrain do
  let(:config) do
    CoindcxBot::Config.new(
      minimal_bot_config(
        smc_setup: {
          enabled: true,
          planner_enabled: true,
          planner_min_candles: 30,
          planner_ohlcv_tail: 8,
          use_retry_middleware: false
        },
        strategy: {
          execution_resolution: '15m',
          higher_timeframe_resolution: '1h',
          smc_confluence: { min_score: 10, vp_bars: 8, smc_swing: 3, ms_swing: 3 }
        }
      )
    )
  end

  let(:pair) { 'B-SOL_USDT' }

  let(:planner_context) do
    candles = Array.new(40) do |i|
      CoindcxBot::Dto::Candle.new(
        time: Time.utc(2024, 6, 1) + (i * 900),
        open: 100 + i * 0.1,
        high: 101 + i * 0.1,
        low: 99 + i * 0.1,
        close: 100.5 + i * 0.1,
        volume: 1000 + i
      )
    end
    CoindcxBot::SmcSetup::PlannerContext.build(
      pairs: [pair],
      candles_by_pair: { pair => candles },
      open_count: 0,
      exec_resolution: '15m',
      htf_resolution: '1h',
      strategy_cfg: config.strategy,
      config: config
    )
  end

  def stub_ollama_json(brain, json_string)
    # Load ollama-client so resolved_model / Ollama::Config resolve (chat itself is stubbed).
    allow(brain).to receive(:ensure_ollama_loaded!) do
      require 'ollama-client'
    end
    chat = double('ollama_chat')
    allow(chat).to receive(:chat).and_return(
      Struct.new(:content).new(json_string)
    )
    allow(brain).to receive(:chat_client).and_return(chat)
  end

  it 'returns no_trade_reason when the model declines' do
    brain = described_class.new(config: config, logger: nil)
    stub_ollama_json(
      brain,
      '{"schema_version":1,"no_trade":true,"pair":"B-SOL_USDT","reason":"conditions not met"}'
    )

    res = brain.plan!(planner_context)

    expect(res.ok).to be(true)
    expect(res.payload).to be_nil
    expect(res.error_message).to be_nil
    expect(res.no_trade_reason).to eq('conditions not met')
  end

  it 'returns payload when the model proposes a setup' do
    brain = described_class.new(config: config, logger: nil)
    # Prices aligned with planner_context LTP (~104 area) for validator anchor band.
    stub_ollama_json(
      brain,
      '{"schema_version":1,"setup_id":"test-setup-1","pair":"B-SOL_USDT","direction":"long",' \
        '"valid_for_minutes":60,"invalidation_level":103.5,' \
        '"conditions":{"sweep_zone":{"min":103.6,"max":103.9},' \
        '"entry_zone":{"min":104.0,"max":104.2},"no_trade_zone":{"min":104.3,"max":105.0},' \
        '"confirmation_required":[]},' \
        '"execution":{"sl":102.5,"targets":[105.5],"risk_usdt":10.0}}'
    )

    res = brain.plan!(planner_context)

    expect(res.ok).to be(true)
    expect(res.payload).to be_a(Hash)
    expect(res.payload[:setup_id]).to eq('test-setup-1')
    expect(res.no_trade_reason).to be_nil
  end
end
