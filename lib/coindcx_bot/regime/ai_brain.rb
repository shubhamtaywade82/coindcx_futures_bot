# frozen_string_literal: true

require 'json'
require_relative '../smc_setup/json_slice'

module CoindcxBot
  module Regime
    # Calls a local Ollama model (ollama-client) with optional exponential backoff (ollama_agent retry middleware).
    # Advisory only: does not place orders; feeds {Engine#snapshot #regime} for the TUI.
    class AiBrain
      # JSON::Ext::Generator rejects many C0 control bytes in string values (see JSON::GeneratorError).
      JSON_UNSAFE_ASCII = /[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/.freeze

      Result = Struct.new(:ok, :payload, :error_message, keyword_init: true)

      SYSTEM_PROMPT = <<~PROMPT.gsub(/\s+/, ' ').strip.freeze
        You are a disciplined crypto USDT-M perpetual futures regime analyst for a multi-pair bot.
        Use only the OHLCV and the open_positions_json array in the user message. No web search, no invented prices.
        The open_positions_json array is authoritative: when you mention an open position you MUST use the exact
        pair, side, entry_price, and quantity from that array. If the array is empty the book is flat — never
        describe an open long or short. Do not contradict those fields under any circumstances.
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
        The user message includes open_positions_json: it is authoritative for open positions (exact pair, side,
        entry_price, quantity). If empty, the book is flat. Never invent or flip position side versus that JSON.
        Narrate agreement or tension with the HMM in your notes; do not invent different state probabilities.
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
        raw = self.class.scrub_json_string(resp.content.to_s)
        hash = parse_response_for_primary_pair(raw, context)
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
          msg = scrub_json_string(err.to_s)
          return {
            active: false,
            hmm_display: truncate(msg, 56),
            ai_transition_full: '',
            ai_notes_full: msg,
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

        flick = scrub_json_string((p[:flicker_hint] || p['flicker_hint']).to_s)
        flick = flick[0, 14] unless flick.empty?

        label = scrub_json_string((p[:regime_label] || p['regime_label']).to_s)
        notes = scrub_json_string((p[:notes] || p['notes']).to_s)
        trans = scrub_json_string((p[:transition_summary] || p['transition_summary']).to_s)
        notes_stripped = notes.strip
        trans_stripped = trans.strip
        label_stripped = label.strip
        hmm_line =
          if !notes_stripped.empty?
            notes_stripped
          elsif !trans_stripped.empty?
            trans_stripped
          elsif !label_stripped.empty?
            label_stripped
          else
            '—'
          end

        {
          active: true,
          label: truncate(label, 14),
          probability_pct: coerce_pct(p[:probability_pct] || p['probability_pct']),
          stability_bars: coerce_int(p[:stability_bars] || p['stability_bars']),
          flicker_display: flick.empty? ? '—' : flick,
          confirmed: coerce_bool(p[:confirmed] || p['confirmed']),
          vol_rank_display: truncate(vol_disp, 14),
          transition_display: truncate(trans, 40),
          hmm_display: truncate("AI: #{hmm_line}", 52),
          ai_transition_full: trans_stripped,
          ai_notes_full: notes_stripped,
          status: 'PIPE:RUN'
        }
      end

      def self.scrub_json_string(s)
        s.to_s.encode('UTF-8', invalid: :replace, undef: :replace, replace: '?').gsub(JSON_UNSAFE_ASCII, ' ')
      end

      def self.scrub_for_json(obj)
        case obj
        when String then scrub_json_string(obj)
        when Hash
          obj.each_with_object({}) do |(k, v), acc|
            nk = k.is_a?(String) || k.is_a?(Symbol) ? k : scrub_json_string(k.to_s)
            acc[nk] = scrub_for_json(v)
          end
        when Array
          obj.map { |e| scrub_for_json(e) }
        else
          obj
        end
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
        m.empty? ? Ollama::Config.new.model : m
      end

      def ollama_config_object
        c = Ollama::Config.new
        u = @config.regime_ai_ollama_base_url
        c.base_url = u unless u.empty?
        k = @config.regime_ai_ollama_api_key
        c.api_key = k unless k.empty?
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

      def parse_response_for_primary_pair(raw, context)
        s = raw.to_s.strip
        s = s.sub(/\A```(?:json)?\s*/i, '').sub(/```\s*\z/m, '')
        if s.start_with?('[')
          arr = JSON.parse(s, symbolize_names: true)
          primary = Array(context[:pairs]).first.to_s
          match = arr.find { |h| h.is_a?(Hash) && (h[:pair].to_s == primary || h['pair'].to_s == primary) }
          return match || arr.find { |h| h.is_a?(Hash) } || {}
        end
        SmcSetup::JsonSlice.parse_object(raw)
      rescue JSON::ParserError
        SmcSetup::JsonSlice.parse_object(raw)
      end

      def build_user_message(context)
        lines = []
        lines << "Execution timeframe: #{context[:exec_resolution]}. Higher timeframe: #{context[:htf_resolution]}."
        lines << 'open_positions_json (authoritative; [] means flat book):'
        positions_json = self.class.scrub_for_json(self.class.serialize_open_positions(Array(context[:positions])))
        lines << JSON.generate(positions_json)
        lines << ''
        feats = context[:features_by_pair]
        if feats.is_a?(Hash) && feats.any?
          lines << 'OHLCV feature packets (JSON, deterministic Ruby layer; use with bar list if present):'
          lines << JSON.generate(self.class.scrub_for_json(feats))
          lines << ''
        end
        Array(context[:pairs]).each do |pair|
          bars = context[:candles_by_pair][pair] || []
          lines << "PAIR #{pair} (#{bars.size} bars, oldest first):"
          if bars.empty? && feats.is_a?(Hash) && feats[pair]
            lines << '  (raw OHLCV lines omitted; see ohlcv feature packet for this pair)'
          end
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

      def self.serialize_open_positions(rows)
        Array(rows).filter_map { |raw| serialize_one_open_position(raw) }
      end

      def self.serialize_one_open_position(raw)
        return nil unless raw.is_a?(Hash)

        h = raw.transform_keys { |k| k.to_sym }
        pair = h[:pair].to_s.strip
        return nil if pair.empty?

        side = h[:side].to_s.strip.downcase
        out = {
          pair: pair,
          side: side,
          entry_price: h[:entry_price].to_s.strip,
          quantity: h[:quantity].to_s.strip
        }
        pid = (h[:id] || h[:position_id])&.to_s&.strip
        out[:position_id] = pid if pid && !pid.empty?

        optional_position_fields(h, out)
        out
      end

      def self.optional_position_fields(h, out)
        %i[stop_price trail_price initial_stop_price peak_ltp].each do |k|
          v = h[k]
          next if v.nil? || v.to_s.strip.empty?

          out[k] = v.to_s.strip
        end
      end

      def normalize_payload(h)
        {
          regime_label: self.class.scrub_json_string((h[:regime_label] || h['regime_label']).to_s),
          probability_pct: self.class.coerce_pct(h[:probability_pct] || h['probability_pct']),
          stability_bars: self.class.coerce_int(h[:stability_bars] || h['stability_bars']),
          flicker_hint: self.class.scrub_json_string((h[:flicker_hint] || h['flicker_hint']).to_s),
          confirmed: self.class.coerce_bool(h[:confirmed] || h['confirmed']),
          vol_rank: self.class.coerce_int(h[:vol_rank] || h['vol_rank']),
          vol_rank_total: self.class.coerce_int(h[:vol_rank_total] || h['vol_rank_total']),
          transition_summary: self.class.scrub_json_string((h[:transition_summary] || h['transition_summary']).to_s),
          notes: self.class.scrub_json_string((h[:notes] || h['notes']).to_s)
        }
      end
    end
  end
end
