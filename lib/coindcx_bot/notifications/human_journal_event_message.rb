# frozen_string_literal: true

require 'bigdecimal'
require 'json'

module CoindcxBot
  module Notifications
    # Turns journal +event_log+ rows into short plain-text copy for Telegram.
    module HumanJournalEventMessage
      class << self
        def format(type, payload)
          h = normalize_payload(payload)
          inner =
            case type.to_s
            when 'signal_open' then format_signal_open(h)
            when 'open_failed' then format_open_failed(h)
            when 'signal_close' then format_signal_close(h)
            when 'signal_partial' then format_signal_partial(h)
            when 'trail' then format_trail(h)
            when 'flatten' then format_flatten(h)
            when 'paper_realized' then format_paper_realized(h)
            when 'ws_order_update' then format_ws_order_update(h)
            when 'smc_setup_fired' then format_smc_setup_fired(h)
            when 'smc_setup_invalidated' then format_smc_setup_invalidated(h)
            when 'analysis_strategy_transition' then format_analysis_strategy_transition(h)
            when 'analysis_regime_change' then format_analysis_regime_change(h)
            when 'analysis_regime_ai_update' then format_analysis_regime_ai_update(h)
            when 'analysis_price_cross' then format_analysis_price_cross(h)
            when 'analysis_liquidation_proximity' then format_analysis_liquidation_proximity(h)
            else format_fallback(type, h)
            end

          "coindcx-bot | #{type}\n#{inner}".strip
        end

        private

        def normalize_payload(payload)
          return {} unless payload.is_a?(Hash)

          payload.each_with_object({}) do |(k, v), acc|
            key = k.respond_to?(:to_sym) ? k.to_sym : k
            acc[key] = v
          end
        end

        def format_signal_open(h)
          action = fetch_s(h, :action)
          pair = fetch_s(h, :pair)
          lines = []
          if pair != '' && action != ''
            lines << "#{action_phrase(action)} · #{pair}"
          elsif pair != ''
            lines << "Pair: #{pair}"
          elsif action != ''
            lines << action_phrase(action).to_s
          end
          lines << "Reason: #{fetch_s(h, :reason)}" if fetch_s(h, :reason) != ''
          lev = fetch_s(h, :leverage)
          lines << "Leverage: #{lev}x" if lev != ''
          lines.empty? ? 'Open signal (no details)' : lines.join("\n")
        end

        def action_phrase(action)
          case action.to_s.downcase
          when 'open_long' then 'Open LONG'
          when 'open_short' then 'Open SHORT'
          else "Open (#{action})"
          end
        end

        def format_open_failed(h)
          lines = ['Open failed']
          lines << "Pair: #{fetch_s(h, :pair)}" if fetch_s(h, :pair) != ''
          lines << "Action: #{fetch_s(h, :action)}" if fetch_s(h, :action) != ''
          lines << "Reason: #{fetch_s(h, :reason)}" if fetch_s(h, :reason) != ''
          lines << "Detail: #{fetch_s(h, :detail)}" if fetch_s(h, :detail) != ''
          lines.join("\n")
        end

        def format_signal_close(h)
          lines = ['Close']
          lines << "Pair: #{fetch_s(h, :pair)}" if fetch_s(h, :pair) != ''
          lines << "Reason: #{fetch_s(h, :reason)}" if fetch_s(h, :reason) != ''
          pid = fetch_s(h, :position_id)
          lines << "Position: ##{pid}" if pid != ''
          lines << "Outcome: #{fetch_s(h, :outcome)}" if fetch_s(h, :outcome) != ''
          lines << "PnL booked: #{truthy_phrase(h[:pnl_booked])}"
          lines.join("\n")
        end

        def format_signal_partial(h)
          lines = ['Partial exit recorded']
          lines << "Pair: #{fetch_s(h, :pair)}" if fetch_s(h, :pair) != ''
          pid = fetch_s(h, :position_id)
          lines << "Position: ##{pid}" if pid != ''
          lines.join("\n")
        end

        def format_trail(h)
          lines = ['Trail / stop update']
          pid = fetch_s(h, :position_id)
          lines << "Position: ##{pid}" if pid != ''
          lines << "New stop: #{fetch_s(h, :stop)}" if fetch_s(h, :stop) != ''
          lines.join("\n")
        end

        def format_flatten(h)
          "Flatten\nPair: #{fetch_s(h, :pair)}"
        end

        def format_paper_realized(h)
          lines = ['Paper PnL (realized)']
          lines << "Pair: #{fetch_s(h, :pair)}" if fetch_s(h, :pair) != ''
          pid = fetch_s(h, :position_id)
          lines << "Position: ##{pid}" if pid != ''
          usdt = round_money(fetch_s(h, :pnl_usdt), 4)
          inr = round_money(fetch_s(h, :pnl_inr), 2)
          lines << "PnL: #{usdt} USDT (~₹#{inr})" if usdt != '' || inr != ''
          ex = round_money(fetch_s(h, :exit_price), 4)
          lines << "Exit: #{ex}" if ex != ''
          src = fetch_s(h, :source)
          lines << "Source: #{src}" if src != ''
          lines.join("\n")
        end

        def format_ws_order_update(h)
          lines = ['Order (WebSocket update)']
          %i[event status id order_id client_order_id s p].each do |key|
            val = fetch_s(h, key)
            next if val == ''

            label =
              case key
              when :s then 'side'
              when :p then 'pair'
              else key.to_s.tr('_', ' ')
              end
            lines << "#{label}: #{val}"
          end
          lines.size > 1 ? lines.join("\n") : "Order (WebSocket update)\n(no fields)"
        end

        def format_smc_setup_fired(h)
          lines = ['SMC setup entry fired']
          lines << "Setup: #{fetch_s(h, :setup_id)}" if fetch_s(h, :setup_id) != ''
          lines << "Pair: #{fetch_s(h, :pair)}" if fetch_s(h, :pair) != ''
          lines.join("\n")
        end

        def format_smc_setup_invalidated(h)
          lines = ['SMC setup invalidated']
          lines << "Pair: #{fetch_s(h, :pair)}" if fetch_s(h, :pair) != ''
          lines << "Setup: #{fetch_s(h, :setup_id)}" if fetch_s(h, :setup_id) != ''
          lines << "Reason: #{fetch_s(h, :reason)}" if fetch_s(h, :reason) != ''
          lines.join("\n")
        end

        def format_analysis_strategy_transition(h)
          lines = ['Strategy signal change']
          lines << "Pair: #{fetch_s(h, :pair)}" if fetch_s(h, :pair) != ''
          lines << "From: #{fetch_s(h, :from_action)} (#{fetch_s(h, :from_reason)})" if fetch_s(h, :from_action) != ''
          lines << "To: #{fetch_s(h, :to_action)} (#{fetch_s(h, :to_reason)})" if fetch_s(h, :to_action) != ''
          lines << "LTP: #{fetch_s(h, :ltp)}" if fetch_s(h, :ltp) != ''
          lines.join("\n")
        end

        def format_analysis_regime_change(h)
          lines = ['HMM regime change']
          lines << "Pair: #{fetch_s(h, :pair)}" if fetch_s(h, :pair) != ''
          lines << "From: #{fetch_s(h, :from_label)} (state #{fetch_s(h, :from_state_id)})" if fetch_s(h, :from_label) != ''
          lines << "To: #{fetch_s(h, :to_label)} (state #{fetch_s(h, :to_state_id)})" if fetch_s(h, :to_label) != ''
          lines << "Meaning: #{fetch_s(h, :meaning)}" if fetch_s(h, :meaning) != ''
          posterior = fetch_s(h, :probability_pct)
          if posterior != ''
            stab = fetch_s(h, :stability_bars)
            stab_part = stab == '' ? '' : " · stability #{stab} bars"
            lines << "Confidence: #{posterior}%#{stab_part}"
          end
          if fetch_s(h, :vol_rank) != '' && fetch_s(h, :vol_rank_total) != ''
            lines << "Volatility rank: #{fetch_s(h, :vol_rank)}/#{fetch_s(h, :vol_rank_total)}"
          end
          lines << "Bias: #{fetch_s(h, :bias)}" if fetch_s(h, :bias) != ''
          lines << "Action: #{fetch_s(h, :action)}" if fetch_s(h, :action) != ''
          lines.join("\n")
        end

        def format_analysis_regime_ai_update(h)
          lines = ['Regime AI update']
          lines << "Label: #{fetch_s(h, :regime_label)} (was #{fetch_s(h, :prev_label)})" if fetch_s(h, :regime_label) != ''
          lines << "Prob: #{fetch_s(h, :probability_pct)}% (was #{fetch_s(h, :prev_probability_pct)}%)" if fetch_s(h, :probability_pct) != ''
          lines << "Summary: #{fetch_s(h, :transition_summary)}" if fetch_s(h, :transition_summary) != ''
          lines.join("\n")
        end

        def format_analysis_price_cross(h)
          lines = ['Price level cross (LTP)']
          lines << "#{fetch_s(h, :label)} (#{fetch_s(h, :rule_id)})" if fetch_s(h, :label) != '' || fetch_s(h, :rule_id) != ''
          lines << "Pair: #{fetch_s(h, :pair)}" if fetch_s(h, :pair) != ''
          lines << "Thresholds: #{fetch_s(h, :threshold_summary)}" if fetch_s(h, :threshold_summary) != ''
          lines << "Cross: #{fetch_s(h, :direction)} @ #{fetch_s(h, :price)} — #{fetch_s(h, :level)}" if fetch_s(h, :price) != ''
          if fetch_s(h, :strategy_action) != ''
            lines << "Strategy: #{fetch_s(h, :strategy_action)} (#{fetch_s(h, :strategy_reason)})"
          end
          if fetch_s(h, :hmm_label) != ''
            lines << "HMM: #{fetch_s(h, :hmm_label)} s#{fetch_s(h, :hmm_state_id)} p=#{fetch_s(h, :hmm_posterior_pct)}% " \
                     "vol #{fetch_s(h, :hmm_vol_rank)} uncertain=#{truthy_phrase(fetch_s(h, :hmm_uncertain))}"
          end
          if fetch_s(h, :regime_ai_label) != ''
            lines << "Regime AI (book-wide): #{fetch_s(h, :regime_ai_label)} (#{fetch_s(h, :regime_ai_probability_pct)}%)"
          end
          lines.join("\n")
        end

        def format_analysis_liquidation_proximity(h)
          lines = ['Liquidation proximity']
          lines << "Pair: #{fetch_s(h, :pair)}" if fetch_s(h, :pair) != ''
          lines << "Distance: #{fetch_s(h, :distance_pct)}%" if fetch_s(h, :distance_pct) != ''
          lines << "Mark: #{fetch_s(h, :mark)} liq: #{fetch_s(h, :liquidation)}" if fetch_s(h, :mark) != ''
          lines.join("\n")
        end

        def format_fallback(type, h)
          return 'coindcx-bot (empty payload)' if h.empty?

          lines = ["Event: #{type}"]
          h.keys.sort_by(&:to_s).each do |key|
            lines << "#{key}: #{truncate_value(h[key])}"
          end
          body = lines.join("\n")
          return body if body.length <= 3_000

          "#{body[0, 3_000]}…\n(truncated)"
        end

        def fetch_s(h, key)
          v = h[key]
          v.nil? ? '' : v.to_s.strip
        end

        def truthy_phrase(v)
          v == true || v.to_s.downcase == 'true' || v.to_s == '1' ? 'yes' : 'no'
        end

        def round_money(raw, decimals)
          return '' if raw.nil? || raw.to_s.strip.empty?

          bd = BigDecimal(raw.to_s)
          bd.round(decimals, BigDecimal::ROUND_HALF_UP).to_s('F')
        rescue ArgumentError, TypeError
          raw.to_s
        end

        def truncate_value(v)
          s = v.is_a?(Hash) || v.is_a?(Array) ? JSON.generate(v) : v.to_s
          s.length > 240 ? "#{s[0, 240]}…" : s
        end
      end
    end
  end
end
