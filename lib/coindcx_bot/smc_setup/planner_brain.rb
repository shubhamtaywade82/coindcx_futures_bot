# frozen_string_literal: true

require 'json'
require_relative 'json_slice'
require_relative 'validator'

module CoindcxBot
  module SmcSetup
    # Async/low-frequency Ollama planner: returns one TradeSetup-shaped JSON object (schema v1).
    class PlannerBrain
      SYSTEM_PROMPT = <<~PROMPT.gsub(/\s+/, ' ').strip.freeze
        You are an SMC-style trade planner for CoinDCX USDT-M perpetual futures.
        Input per pair: market_state JSON (structure, liquidity, smc with displacement/inducement/mitigation/OBs/FVG,
        volume_profile, volatility, mean, orderflow flags, state) plus optional ohlcv_features and a short OHLCV tail.
        Use ONLY provided fields. orderflow.exchange_delta_available is false: do not claim delta/CVD.
        Prefer setups when smc.displacement.present is true, liquidity.event is not none OR state.is_post_sweep is true,
        and smc.mitigation.status is untouched or partial with a real OB zone.

        If no trade is found, return exactly:
        {
          "schema_version": 1,
          "no_trade": true,
          "pair": "B-SOL_USDT",
          "reason": "short explanation why no trade was found"
        }

        JSON structure:
        {
          "schema_version": 1,
          "setup_id": "unique_string",
          "pair": "B-SOL_USDT",
          "direction": "long",
          "valid_for_minutes": 60,
          "invalidation_level": 82.5,
          "conditions": {
            "sweep_zone": { "min": 83.0, "max": 83.5 },
            "entry_zone": { "min": 84.0, "max": 84.5 },
            "no_trade_zone": { "min": 84.5, "max": 86.0 },
            "confirmation_required": ["choch_bull", "displacement"]
          },
          "execution": {
            "sl": 82.0,
            "targets": [88.0, 90.0],
            "risk_usdt": 10.0
          }
        }

        Prices must be justified by market_state or OHLCV tail. setup_id must be new per call.
        ANCHOR RULE: every numeric price (sweep_zone, entry_zone, no_trade_zone, sl, targets, invalidation_level)
        MUST stay within +/- 5% of the current_price provided in the user message for that pair. Reject any setup outside that band.
        Do not invent prices from training data.
        If you cannot produce a valid setup within that band, return a "no_trade": true JSON.
      PROMPT

      Result = Struct.new(:ok, :payload, :error_message, keyword_init: true)

      def initialize(config:, logger: nil)
        @config = config
        @logger = logger
        @chat_client = nil
      end

      def plan!(context)
        ensure_ollama_loaded!
        messages = [
          { role: 'system', content: SYSTEM_PROMPT },
          { role: 'user', content: build_user_message(context) }
        ]
        resp = chat_client.chat(
          messages: messages,
          model: resolved_model,
          format: 'json',
          stream: false,
          options: { temperature: @config.smc_setup_temperature }
        )
        raw = resp.content.to_s
        h = JsonSlice.parse_object(raw)
        h = unwrap_array_payload(h)
        h = repair_missing_keys!(h)

        if h.is_a?(Hash) && (h[:no_trade] || h['no_trade'] || h[:setup_id].to_s.include?('no_trade'))
          @logger&.info("[smc_setup:planner] planner returned no_trade: #{h[:reason] || h['reason']}")
          return Result.new(ok: true, payload: nil, error_message: nil)
        end

        h = Validator.validate!(h)
        Result.new(ok: true, payload: h, error_message: nil)
      rescue StandardError => e
        @logger&.warn("[smc_setup:planner] #{e.class}: #{e.message}")
        Result.new(ok: false, payload: nil, error_message: e.message.to_s)
      end

      private

      def repair_missing_keys!(h)
        return h unless h.is_a?(Hash)

        h[:schema_version] ||= 1
        h
      end

      def unwrap_array_payload(h)
        return h.first if h.is_a?(Array) && h.first.is_a?(Hash)
        return h unless h.is_a?(Hash) && h.key?(:setups) && h[:setups].is_a?(Array)

        arr = h[:setups]
        return h if arr.empty?

        first = arr.first
        first.is_a?(Hash) ? first : h
      end

      def build_user_message(context)
        lines = []
        lines << 'Analyze the following structured market state for crypto futures (CoinDCX).'
        lines << "Execution TF: #{context[:exec_resolution]}. HTF: #{context[:htf_resolution]}."
        lines << "Open positions: #{context[:open_count].to_i}."

        ms = context[:market_state_by_pair] || {}
        feat = context[:features_by_pair] || {}

        ltps = context[:ltps_by_pair] || {}
        Array(context[:pairs]).each do |p|
          lines << "--- Pair #{p} ---"
          ltp = ltps[p] || ltps[p.to_s]
          if ltp
            lines << "current_price: #{ltp}"
            lines << "PRICE ANCHOR: All proposed sweep_zone, entry_zone, sl, targets, no_trade_zone " \
                     "MUST be within +/- 5% of current_price (#{ltp}). Reject any setup outside that band. " \
                     "Do not invent prices from training data."
          end
          if ms[p]
            lines << 'market_state:'
            lines << JSON.pretty_generate(ms[p])
          end
          if feat[p] && !feat[p].empty?
            lines << 'ohlcv_features (deterministic, no true order flow):'
            lines << JSON.pretty_generate(feat[p])
          end
          tail = context.dig(:candles_by_pair, p) || []
          lines << "recent_ohlcv_tail: #{JSON.generate(tail)}" unless tail.empty?
        end

        lines.join("\n")
      end

      def ensure_ollama_loaded!
        require 'ollama-client'
      end

      def resolved_model
        m = @config.smc_setup_model
        m.empty? ? Ollama::Config.new.model : m
      end

      def ollama_config_object
        c = Ollama::Config.new
        u = @config.smc_setup_ollama_base_url
        c.base_url = u unless u.empty?
        k = @config.smc_setup_ollama_api_key
        c.api_key = k unless k.empty?
        c.timeout = @config.smc_setup_timeout_seconds
        c.temperature = @config.smc_setup_temperature
        c
      end

      def chat_client
        @chat_client ||= build_chat_client
      end

      def build_chat_client
        if @config.smc_setup_use_retry_middleware?
          require 'ollama_agent/ollama_connection'
          require 'ollama_agent/resilience/retry_middleware'
          base = @config.smc_setup_ollama_base_url
          OllamaAgent::OllamaConnection.retry_wrapped_client(
            timeout: @config.smc_setup_timeout_seconds,
            max_attempts: @config.smc_setup_retry_attempts,
            base_url: base.empty? ? nil : base
          )
        else
          Ollama::Client.new(config: ollama_config_object)
        end
      end
    end
  end
end
