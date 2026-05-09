# frozen_string_literal: true

RSpec.describe CoindcxBot::TradingAi::TuiAnalysisBrain do
  subject(:brain) { described_class.new(config: config, logger: nil) }

  let(:config) do
    instance_double(
      CoindcxBot::Config,
      tui_ai_analysis_model: 'llama3.1:8b',
      regime_ai_ollama_base_url: '',
      regime_ai_ollama_api_key: '',
      regime_ai_fallback_ollama_base_url: 'http://127.0.0.1:11435',
      regime_ai_fallback_model: 'qwen2.5:7b',
      regime_ai_fallback_ollama_api_key: '',
      regime_ai_use_retry_middleware?: false,
      regime_ai_retry_attempts: 3,
      tui_ai_analysis_timeout_seconds: 30
    )
  end

  describe '#analyze!' do
    let(:context) do
      {
        pair: 'B-SOL_USDT',
        current_price: 93.12,
        candles: [{ o: 92.8, h: 93.4, l: 92.5, c: 93.1, v: 1234 }],
        htf_candles: [{ o: 92.0, h: 94.0, l: 91.5, c: 93.2, v: 9876 }],
        strategy_signal: { action: 'hold', reason: 'neutral' },
        regime_context: { regime_label: 'TRANSITION' },
        smc_setups: [],
        smc_state: { active_setup_count: 0, all_setups: [] },
        orderflow: { mid: 93.1 },
        open_position: {},
        recent_fills: [],
        recent_events: [{ type: :bos, at: 1, payload: { pair: 'B-SOL_USDT' } }],
        exec_resolution: '5m',
        htf_resolution: '1h'
      }
    end

    it 'normalizes AI response payload into stable shape' do
      response = instance_double('resp', content: <<~JSON)
        {
          "pair":"B-SOL_USDT",
          "side":"long",
          "confidence_pct":"72.55",
          "entry_zone":{"min":"92.9","max":"93.2"},
          "stop_loss":"92.4",
          "targets":["93.8","94.2"],
          "levels_to_watch":[92.7,"93.5"],
          "rationale":"Confluence supports continuation."
        }
      JSON
      allow(CoindcxBot::OllamaChatFallback).to receive(:chat_with_local_fallback).and_return(response)
      allow(brain).to receive(:ensure_ollama_loaded!).and_return(true)
      allow(brain).to receive(:chat_client).and_return(double('ollama_client'))

      result = brain.analyze!(context)

      expect(result.ok).to be(true)
      expect(result.payload[:side]).to eq('LONG')
      expect(result.payload[:confidence_pct]).to eq(72.55)
      expect(result.payload[:entry_zone]).to eq(min: 92.9, max: 93.2)
      expect(result.payload[:stop_loss]).to eq(92.4)
      expect(result.payload[:targets]).to eq([93.8, 94.2])
      expect(result.payload[:levels_to_watch]).to eq([92.7, 93.5])
    end
  end

  describe '.overlay_from_state' do
    it 'returns WAIT when no payload exists yet' do
      overlay = described_class.overlay_from_state(enabled: true, pair: 'B-SOL_USDT')
      expect(overlay[:status]).to eq('WAIT')
    end

    it 'returns ERR overlay when analysis failed' do
      overlay = described_class.overlay_from_state(enabled: true, pair: 'B-SOL_USDT', error: 'timeout')
      expect(overlay[:status]).to eq('ERR')
      expect(overlay[:rationale]).to eq('timeout')
    end
  end
end
