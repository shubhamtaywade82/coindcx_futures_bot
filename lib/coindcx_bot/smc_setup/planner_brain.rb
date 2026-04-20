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
        Use only OHLCV summaries and levels provided. No web search, no invented prices.
        Return a single JSON object matching schema_version 1 with keys:
        schema_version (integer 1), setup_id (unique string), pair (instrument code),
        direction (long or short), optional leverage, optional gatekeeper (boolean),
        conditions with sweep_zone and entry_zone (each min/max numbers) and optional confirmation_required (array of strings:
        choch_bull, choch_bear, choch_up, choch_down, bos_bull, bos_bear, displacement, displacement_bull, displacement_bear),
        execution with sl (stop loss price number) and optional targets array and optional risk_usdt.
        Zones must use realistic prices from the data. setup_id must be new and unique per call.
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
        Validator.validate!(h)
        Result.new(ok: true, payload: Validator.deep_symbolize(h), error_message: nil)
      rescue StandardError => e
        @logger&.warn("[smc_setup:planner] #{e.class}: #{e.message}")
        Result.new(ok: false, payload: nil, error_message: e.message.to_s)
      end

      private

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
        lines << "Execution TF: #{context[:exec_resolution]}. HTF: #{context[:htf_resolution]}."
        lines << "Open positions: #{context[:open_count].to_i}."
        Array(context[:pairs]).each do |p|
          lines << "Pair #{p}: exec OHLCV tail: #{JSON.generate(context.dig(:candles_by_pair, p) || [])}"
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
