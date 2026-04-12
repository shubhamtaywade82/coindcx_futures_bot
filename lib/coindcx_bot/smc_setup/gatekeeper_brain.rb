# frozen_string_literal: true

require 'json'
require_relative 'json_slice'

module CoindcxBot
  module SmcSetup
    # Optional Ollama JSON gate on 5–10 closed bars after deterministic preconditions (fail-closed).
    class GatekeeperBrain
      SYSTEM_PROMPT = <<~PROMPT.gsub(/\s+/, ' ').strip.freeze
        You are a risk gate for a USDT-M futures bot. You receive a trade setup summary and recent OHLCV bars (JSON).
        Return a single JSON object with keys: execute_trade (boolean), reason (short string).
        If uncertain or data is thin, set execute_trade to false.
      PROMPT

      def initialize(config:, logger: nil)
        @config = config
        @logger = logger
        @chat_client = nil
      end

      def approve?(rec:, bar:, bars_json:)
        return false if bars_json.nil? || bars_json.empty?

        ensure_ollama_loaded!
        messages = [
          { role: 'system', content: SYSTEM_PROMPT },
          { role: 'user', content: build_user_payload(rec, bar, bars_json) }
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
        ok = truthy?(h[:execute_trade] || h['execute_trade'])
        @logger&.info("[smc_setup:gatekeeper] #{rec.setup_id} execute_trade=#{ok} #{h[:reason]}") if trace?
        ok
      rescue StandardError => e
        @logger&.warn("[smc_setup:gatekeeper] #{e.class}: #{e.message}")
        false
      end

      private

      def trace?
        ENV['COINDCX_STRATEGY_SIGNALS'].to_s == '1'
      end

      def truthy?(v)
        v == true || v.to_s.downcase == 'true' || v.to_s == '1'
      end

      def build_user_payload(rec, bar, bars_json)
        slice = {
          setup_id: rec.setup_id,
          pair: rec.pair,
          direction: rec.trade_setup.direction.to_s,
          sweep: { min: rec.trade_setup.sweep_min.to_f, max: rec.trade_setup.sweep_max.to_f },
          entry: { min: rec.trade_setup.entry_min.to_f, max: rec.trade_setup.entry_max.to_f },
          confirmations: rec.trade_setup.confirmations,
          last_bar_flags: bar_flags(bar),
          recent_bars: bars_json
        }
        JSON.generate(slice)
      end

      def bar_flags(bar)
        return {} unless bar

        {
          choch_bull: bar.choch_bull,
          choch_bear: bar.choch_bear,
          bos_bull: bar.bos_bull,
          bos_bear: bar.bos_bear
        }
      end

      def ensure_ollama_loaded!
        require 'ollama-client'
      end

      def resolved_model
        m = @config.smc_setup_model
        return m unless m.empty?

        %w[OLLAMA_AGENT_MODEL OLLAMA_MODEL].each do |k|
          v = ENV.fetch(k, '').to_s.strip
          return v unless v.empty?
        end

        Ollama::Config.new.model
      end

      def ollama_config_object
        c = Ollama::Config.new
        u = @config.smc_setup_ollama_base_url
        c.base_url = u unless u.empty?
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
