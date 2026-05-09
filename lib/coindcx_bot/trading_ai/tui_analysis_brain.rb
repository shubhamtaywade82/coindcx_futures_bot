# frozen_string_literal: true

require 'json'
require_relative '../smc_setup/json_slice'
require_relative '../ollama_chat_fallback'

module CoindcxBot
  module TradingAi
    # LLM-only synthesis for TUI trade setup guidance.
    class TuiAnalysisBrain
      Result = Struct.new(:ok, :payload, :error_message, keyword_init: true)

      SYSTEM_PROMPT = <<~PROMPT.gsub(/\s+/, ' ').strip.freeze
        You are a disciplined crypto futures execution analyst for CoinDCX USDT-M pairs.
        You receive a focus-asset context bundle: pair, current_price, exec/htf candles,
        smc_state (active OBs/FVGs/liquidity, BOS/CHoCH log, all setups),
        orderflow (delta/CVD/imbalance/footprint), regime (HMM state, vol metrics, trend),
        open_position, strategy_signal, recent_fills, and recent_events.
        recent_events is the trigger for THIS analysis: weight reasoning around them
        (smc setup transitions, sweeps, BOS/CHoCH, regime flips, position lifecycle, signal flips).
        If recent_events is empty this is a heartbeat — assess current state.
        Return ONE JSON object with actionable guidance for the provided pair only.
        Use only user-provided data; never invent prices far from the given current_price.
        Required keys: pair, side, confidence_pct, entry_zone, stop_loss, targets, levels_to_watch, rationale.
        side must be one of LONG, SHORT, NO_TRADE.
        confidence_pct must be 0..100.
        entry_zone must be an object: { "min": number, "max": number } (use nulls for NO_TRADE).
        stop_loss must be a number or null.
        targets and levels_to_watch must be arrays of numbers (empty for NO_TRADE).
        rationale must be one concise sentence.
        Keep all numeric levels within +/- 6% of current_price unless side is NO_TRADE.
        Respond with JSON only.
      PROMPT

      def initialize(config:, logger: nil)
        @config = config
        @logger = logger
        @chat_client = nil
      end

      def analyze!(context)
        ensure_ollama_loaded!
        messages = [
          { role: 'system', content: SYSTEM_PROMPT },
          { role: 'user', content: build_user_message(context) }
        ]
        opts = { temperature: 0.1 }
        resp = OllamaChatFallback.chat_with_local_fallback(
          logger: @logger,
          log_tag: 'tui_ai_analysis',
          messages: messages,
          format: 'json',
          stream: false,
          options: opts,
          primary_client: chat_client,
          primary_model: @config.tui_ai_analysis_model,
          primary_base_url: @config.regime_ai_ollama_base_url,
          fallback_base_url: @config.regime_ai_fallback_ollama_base_url,
          fallback_model: @config.regime_ai_fallback_model,
          fallback_api_key: @config.regime_ai_fallback_ollama_api_key,
          fallback_timeout: @config.tui_ai_analysis_timeout_seconds,
          fallback_temperature: 0.1
        )
        hash = parse_response(resp.content.to_s)
        Result.new(ok: true, payload: normalize_payload(hash), error_message: nil)
      rescue StandardError => e
        @logger&.warn("[tui_ai_analysis] #{e.class}: #{e.message}")
        Result.new(ok: false, payload: nil, error_message: e.message.to_s)
      end

      def self.overlay_from_state(state)
        st = state.is_a?(Hash) ? state : {}
        return { enabled: false, status: 'OFF' } unless st[:enabled]

        err = st[:error].to_s.strip
        unless err.empty?
          return {
            enabled: true,
            status: 'ERR',
            pair: st[:pair].to_s,
            rationale: err
          }
        end

        payload = st[:payload]
        return { enabled: true, status: 'WAIT', pair: st[:pair].to_s } unless payload.is_a?(Hash)

        payload.merge(
          enabled: true,
          status: 'OK',
          updated_at: st[:updated_at]
        )
      end

      private

      def ensure_ollama_loaded!
        require 'ollama-client'
      end

      def build_user_message(context)
        # Compact JSON dump of the focus-asset bundle. Strip private keys.
        payload = context.reject { |k, _| k.to_s.start_with?('_') }
        bundle = {
          pair: payload[:pair],
          current_price: payload[:current_price],
          execution_timeframe: payload[:exec_resolution],
          higher_timeframe: payload[:htf_resolution],
          strategy_signal: payload[:strategy_signal] || {},
          regime_context: payload[:regime_context] || {},
          smc_setups: payload[:smc_setups] || [],
          smc_state: payload[:smc_state] || {},
          orderflow: payload[:orderflow] || {},
          open_position: payload[:open_position] || {},
          recent_fills: payload[:recent_fills] || [],
          recent_events: payload[:recent_events] || [],
          exec_candles: payload[:candles] || [],
          htf_candles: payload[:htf_candles] || []
        }
        JSON.generate(bundle)
      end

      def parse_response(raw)
        s = raw.to_s.strip
        s = s.sub(/\A```(?:json)?\s*/i, '').sub(/```\s*\z/m, '')
        SmcSetup::JsonSlice.parse_object(s)
      end

      def normalize_payload(hash)
        h = hash.is_a?(Hash) ? hash : {}
        {
          pair: string_or_blank(h[:pair] || h['pair']),
          side: normalize_side(h[:side] || h['side']),
          confidence_pct: normalize_confidence(h[:confidence_pct] || h['confidence_pct']),
          entry_zone: normalize_zone(h[:entry_zone] || h['entry_zone']),
          stop_loss: normalize_number(h[:stop_loss] || h['stop_loss']),
          targets: normalize_number_array(h[:targets] || h['targets']),
          levels_to_watch: normalize_number_array(h[:levels_to_watch] || h['levels_to_watch']),
          rationale: string_or_blank(h[:rationale] || h['rationale'])
        }
      end

      def normalize_side(raw)
        value = string_or_blank(raw).upcase
        return 'LONG' if value == 'LONG'
        return 'SHORT' if value == 'SHORT'

        'NO_TRADE'
      end

      def normalize_confidence(raw)
        return 0.0 if raw.nil?

        Float(raw).clamp(0.0, 100.0).round(2)
      rescue ArgumentError, TypeError
        0.0
      end

      def normalize_zone(raw)
        zone = raw.is_a?(Hash) ? raw : {}
        {
          min: normalize_number(zone[:min] || zone['min']),
          max: normalize_number(zone[:max] || zone['max'])
        }
      end

      def normalize_number_array(raw)
        Array(raw).map { |v| normalize_number(v) }.compact.first(4)
      end

      def normalize_number(raw)
        return nil if raw.nil?

        Float(raw)
      rescue ArgumentError, TypeError
        nil
      end

      def string_or_blank(raw)
        raw.to_s.strip
      end

      def chat_client
        @chat_client ||= build_chat_client
      end

      def build_chat_client
        if @config.regime_ai_use_retry_middleware?
          require 'ollama_agent/ollama_connection'
          require 'ollama_agent/resilience/retry_middleware'
          base = @config.regime_ai_ollama_base_url
          OllamaAgent::OllamaConnection.retry_wrapped_client(
            timeout: @config.tui_ai_analysis_timeout_seconds,
            max_attempts: @config.regime_ai_retry_attempts,
            base_url: base.empty? ? nil : base
          )
        else
          ollama = Ollama::Config.new
          base = @config.regime_ai_ollama_base_url
          ollama.base_url = base unless base.empty?
          api_key = @config.regime_ai_ollama_api_key
          ollama.api_key = api_key unless api_key.empty?
          ollama.timeout = @config.tui_ai_analysis_timeout_seconds
          Ollama::Client.new(config: ollama)
        end
      end
    end
  end
end
