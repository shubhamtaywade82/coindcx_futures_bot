# frozen_string_literal: true

require 'json'

module CoindcxBot
  module Regime
    # Calls a local Ollama model (ollama-client) with optional exponential backoff (ollama_agent retry middleware).
    # Advisory only: does not place orders; feeds {Engine#snapshot #regime} for the TUI.
    class AiBrain
      Result = Struct.new(:ok, :payload, :error_message, keyword_init: true)

      SYSTEM_PROMPT = <<~PROMPT.gsub(/\s+/, ' ').strip.freeze
        You are a disciplined crypto USDT-M perpetual futures regime analyst for a multi-pair bot.
        Use only the OHLCV and position summary provided. No web search, no invented prices.
        Return a single JSON object with these keys (all required):
        regime_label (short string, e.g. TREND_UP, TREND_DOWN, RANGING, HIGH_VOL, LOW_VOL, TRANSITION),
        probability_pct (0-100 number, confidence in regime_label),
        stability_bars (integer 0-50, how many recent bars the regime appears stable),
        flicker_hint (string: low, medium, or high regime churn),
        confirmed (boolean, true if you would act on this view),
        vol_rank (integer 1-5, 1=lowest vol among regimes you infer),
        vol_rank_total (integer, usually 5),
        transition_summary (short string, plain text),
        notes (one short sentence rationale).
      PROMPT

      SYSTEM_PROMPT_WITH_HMM = <<~PROMPT.gsub(/\s+/, ' ').strip.freeze
        You review OHLCV plus a **quantitative HMM regime summary** already computed by the bot.
        Narrate agreement or tension with that summary in your notes; do not invent different state probabilities.
        Same JSON keys as the base analyst (regime_label, probability_pct, stability_bars, flicker_hint, confirmed,
        vol_rank, vol_rank_total, transition_summary, notes). If you disagree with the HMM, say so briefly in notes
        and set confirmed to false.
      PROMPT

      def initialize(config:, logger: nil)
        @config = config
        @logger = logger
        @chat_client = nil
      end

      def analyze!(context)
        ensure_ollama_loaded!
        hmm = context[:hmm]
        sys =
          if hmm.is_a?(Hash) && !hmm.empty?
            SYSTEM_PROMPT_WITH_HMM
          else
            SYSTEM_PROMPT
          end
        messages = [
          { role: 'system', content: sys },
          { role: 'user', content: build_user_message(context) }
        ]
        model = resolved_model
        resp = chat_client.chat(
          messages: messages,
          model: model,
          format: 'json',
          stream: false,
          options: { temperature: @config.regime_ai_temperature }
        )
        raw = resp.content.to_s
        hash = parse_json_object(raw)
        payload = normalize_payload(hash)
        Result.new(ok: true, payload: payload, error_message: nil)
      rescue StandardError => e
        @logger&.warn("[regime_ai] #{e.class}: #{e.message}")
        Result.new(ok: false, payload: nil, error_message: e.message.to_s)
      end

      def self.overlay_from_state(state)
        st = state.is_a?(Hash) ? state : {}
        err = st[:error].to_s.strip
        unless err.empty?
          return {
            active: false,
            hmm_display: "AI err: #{err[0, 48]}",
            status: 'PIPE:ERR'
          }
        end

        p = st[:payload]
        return {} if p.nil? || !p.is_a?(Hash)

        vr = p[:vol_rank] || p['vol_rank']
        vrt = p[:vol_rank_total] || p['vol_rank_total']
        vol_disp =
          if vr && vrt
            "#{vr}/#{vrt}"
          else
            (p[:vol_rank_display] || p['vol_rank_display']).to_s
          end
        vol_disp = '—' if vol_disp.strip.empty?

        flick = (p[:flicker_hint] || p['flicker_hint']).to_s
        flick = flick[0, 14] unless flick.empty?

        label = (p[:regime_label] || p['regime_label']).to_s
        notes = (p[:notes] || p['notes']).to_s
        trans = (p[:transition_summary] || p['transition_summary']).to_s

        {
          active: true,
          label: truncate(label, 14),
          probability_pct: coerce_pct(p[:probability_pct] || p['probability_pct']),
          stability_bars: coerce_int(p[:stability_bars] || p['stability_bars']),
          flicker_display: flick.empty? ? '—' : flick,
          confirmed: coerce_bool(p[:confirmed] || p['confirmed']),
          vol_rank_display: truncate(vol_disp, 14),
          transition_display: truncate(trans, 28),
          hmm_display: truncate("AI: #{notes}", 40),
          status: 'PIPE:RUN'
        }
      end

      def self.truncate(s, max)
        t = s.to_s
        t.length <= max ? t : "#{t[0, max - 1]}…"
      end

      def self.coerce_pct(v)
        return nil if v.nil?

        Float(v).clamp(0.0, 100.0)
      rescue ArgumentError, TypeError
        nil
      end

      def self.coerce_int(v)
        return nil if v.nil?

        Integer(v)
      rescue ArgumentError, TypeError
        nil
      end

      def self.coerce_bool(v)
        v == true || v.to_s.downcase == 'true'
      end

      private

      def ensure_ollama_loaded!
        require 'ollama-client'
      end

      def resolved_model
        m = @config.regime_ai_model
        return m unless m.empty?

        %w[OLLAMA_AGENT_MODEL OLLAMA_MODEL].each do |k|
          v = ENV.fetch(k, '').to_s.strip
          return v unless v.empty?
        end

        Ollama::Config.new.model
      end

      def ollama_config_object
        c = Ollama::Config.new
        u = @config.regime_ai_ollama_base_url
        c.base_url = u unless u.empty?
        c.timeout = @config.regime_ai_timeout_seconds
        c.temperature = @config.regime_ai_temperature
        c
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
            timeout: @config.regime_ai_timeout_seconds,
            max_attempts: @config.regime_ai_retry_attempts,
            base_url: base.empty? ? nil : base
          )
        else
          Ollama::Client.new(config: ollama_config_object)
        end
      end

      def build_user_message(context)
        lines = []
        lines << "Execution timeframe: #{context[:exec_resolution]}. Higher timeframe: #{context[:htf_resolution]}."
        lines << 'Open positions (journal):'
        Array(context[:positions]).each { |pos| lines << pos.inspect }
        lines << ''
        Array(context[:pairs]).each do |pair|
          bars = context[:candles_by_pair][pair] || []
          lines << "PAIR #{pair} (#{bars.size} bars, oldest first):"
          bars.each_with_index do |b, idx|
            lines << "  #{idx} o=#{b[:o]} h=#{b[:h]} l=#{b[:l]} c=#{b[:c]} v=#{b[:v]}"
          end
          lines << ''
        end
        if context[:hmm].is_a?(Hash) && context[:hmm].any?
          lines << ''
          lines << 'HMM summary (from Ruby forward filter; do not contradict state_id without saying so in notes):'
          context[:hmm].each { |pair, h| lines << "  #{pair}: #{h.inspect}" }
        end
        lines << 'Respond with ONLY the JSON object, no markdown fences.'
        lines.join("\n")
      end

      def parse_json_object(raw)
        s = raw.to_s.strip
        s = s.sub(/\A```(?:json)?\s*/i, '').sub(/```\s*\z/m, '')
        i = s.index('{')
        j = s.rindex('}')
        raise 'no JSON object in model output' if i.nil? || j.nil? || j < i

        JSON.parse(s[i..j], symbolize_names: true)
      end

      def normalize_payload(h)
        {
          regime_label: (h[:regime_label] || h['regime_label']).to_s,
          probability_pct: self.class.coerce_pct(h[:probability_pct] || h['probability_pct']),
          stability_bars: self.class.coerce_int(h[:stability_bars] || h['stability_bars']),
          flicker_hint: (h[:flicker_hint] || h['flicker_hint']).to_s,
          confirmed: self.class.coerce_bool(h[:confirmed] || h['confirmed']),
          vol_rank: self.class.coerce_int(h[:vol_rank] || h['vol_rank']),
          vol_rank_total: self.class.coerce_int(h[:vol_rank_total] || h['vol_rank_total']),
          transition_summary: (h[:transition_summary] || h['transition_summary']).to_s,
          notes: (h[:notes] || h['notes']).to_s
        }
      end
    end
  end
end
