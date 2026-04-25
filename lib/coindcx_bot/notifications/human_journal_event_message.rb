# frozen_string_literal: true

require 'bigdecimal'
require 'json'

module CoindcxBot
  module Notifications
    # Turns journal +event_log+ rows into professional, institutional-grade plain-text for Telegram.
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
            when 'live_realized' then format_live_realized(h)
            when 'ws_order_update' then format_ws_order_update(h)
            when 'smc_setup_identified' then format_smc_setup_identified(h)
            when 'smc_setup_armed' then format_smc_setup_armed(h)
            when 'smc_setup_fired' then format_smc_setup_fired(h)
            when 'smc_setup_invalidated' then format_smc_setup_invalidated(h)
            when 'analysis_strategy_transition' then format_analysis_strategy_transition(h)
            when 'analysis_regime_change' then format_analysis_regime_change(h)
            when 'analysis_regime_ai_update' then format_analysis_regime_ai_update(h)
            when 'analysis_price_cross' then format_analysis_price_cross(h)
            when 'analysis_liquidation_proximity' then format_analysis_liquidation_proximity(h)
            else format_fallback(type, h)
            end

          "#{header_emoji(type)} #{type.to_s.upcase}\n#{inner}".strip
        end

        private

        def header_emoji(type)
          case type.to_s
          when /failed|invalidated/ then '🚫'
          when /fired|open|paper_realized|live_realized/ then '✅'
          when /armed|trail|transition|change/ then '🔄'
          when /signal_close/ then '🛑'
          when /liquidation/ then '⚠️'
          else 'ℹ️'
          end
        end

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
          dir_emoji = action.to_s.include?('long') ? '📈' : '📉'
          lines << "#{dir_emoji} #{action_phrase(action)} · #{pair}"
          lines << "━━━━━━━━━━━━━━━━━━━━"
          lines << "Reason: #{fetch_s(h, :reason)}" if fetch_s(h, :reason) != ''
          lev = fetch_s(h, :leverage)
          lines << "Leverage: #{lev}x" if lev != ''
          lines.empty? ? 'Open signal (no details)' : lines.join("\n")
        end

        def action_phrase(action)
          case action.to_s.downcase
          when 'open_long' then 'LONG'
          when 'open_short' then 'SHORT'
          else action.to_s.upcase
          end
        end

        def format_open_failed(h)
          lines = ["Execution Failed"]
          lines << "Pair: #{fetch_s(h, :pair)}" if fetch_s(h, :pair) != ''
          lines << "Action: #{fetch_s(h, :action).upcase}" if fetch_s(h, :action) != ''
          lines << "Reason: #{fetch_s(h, :reason)}" if fetch_s(h, :reason) != ''
          lines << "Detail: #{fetch_s(h, :detail)}" if fetch_s(h, :detail) != ''
          lines.join("\n")
        end

        def format_signal_close(h)
          lines = ["Exit Signal"]
          lines << "Pair: #{fetch_s(h, :pair)}" if fetch_s(h, :pair) != ''
          lines << "Reason: #{fetch_s(h, :reason)}" if fetch_s(h, :reason) != ''
          pid = fetch_s(h, :position_id)
          lines << "Position: ##{pid}" if pid != ''
          lines << "Outcome: #{fetch_s(h, :outcome).tr('_', ' ').capitalize}" if fetch_s(h, :outcome) != ''
          lines << "PnL Booked: #{truthy_phrase(h[:pnl_booked]).capitalize}"
          lines.join("\n")
        end

        def format_signal_partial(h)
          lines = ['💎 Partial Profit Taken']
          lines << "Pair: #{fetch_s(h, :pair)}" if fetch_s(h, :pair) != ''
          pid = fetch_s(h, :position_id)
          lines << "Position: ##{pid}" if pid != ''
          lines.join("\n")
        end

        def format_trail(h)
          lines = ['🏹 Stop Loss Adjusted']
          pid = fetch_s(h, :position_id)
          lines << "Position: ##{pid}" if pid != ''
          lines << "New Stop: #{fetch_s(h, :stop)}" if fetch_s(h, :stop) != ''
          lines.join("\n")
        end

        def format_flatten(h)
          "🧹 Portfolio Flattened\nPair: #{fetch_s(h, :pair)}"
        end

        def format_paper_realized(h)
          lines = ['📝 Paper PnL Settled']
          lines << "Pair: #{fetch_s(h, :pair)}" if fetch_s(h, :pair) != ''
          pid = fetch_s(h, :position_id)
          lines << "Position: ##{pid}" if pid != ''
          usdt = round_money(fetch_s(h, :pnl_usdt), 4)
          inr = round_money(fetch_s(h, :pnl_inr), 2)
          prefix = BigDecimal(fetch_s(h, :pnl_usdt)).positive? ? '💰' : '💸'
          lines << "#{prefix} PnL: #{usdt} USDT (~₹#{inr})" if usdt != '' || inr != ''
          ex = round_money(fetch_s(h, :exit_price), 4)
          lines << "Exit: #{ex}" if ex != ''
          lines.join("\n")
        end

        def format_live_realized(h)
          lines = ['💳 Live PnL Realized']
          lines << "Pair: #{fetch_s(h, :pair)}" if fetch_s(h, :pair) != ''
          usdt = round_money(fetch_s(h, :pnl_usdt), 4)
          inr = round_money(fetch_s(h, :pnl_inr), 2)
          prefix = BigDecimal(fetch_s(h, :pnl_usdt)).positive? ? '💰' : '💸'
          lines << "#{prefix} PnL: #{usdt} USDT (~₹#{inr})" if usdt != '' || inr != ''
          lines << "Exit: #{round_money(fetch_s(h, :exit_price), 4)}" if fetch_s(h, :exit_price) != ''
          lines << "Note: Estimated" if h[:estimated]
          lines.join("\n")
        end

        def format_ws_order_update(h)
          lines = ['🔔 Order Update']
          %i[event status id order_id client_order_id s p].each do |key|
            val = fetch_s(h, key)
            next if val == ''

            label =
              case key
              when :s then 'Side'
              when :p then 'Pair'
              else key.to_s.tr('_', ' ').capitalize
              end
            lines << "#{label}: #{val}"
          end
          lines.size > 1 ? lines.join("\n") : "Order Update (No Fields)"
        end

        def format_smc_setup_identified(h)
          (['🎯 SMC Setup Detected'] + smc_setup_common_lines(h)).join("\n")
        end

        def format_smc_setup_armed(h)
          lines = ['🔫 SMC Setup Armed']
          lines.concat(smc_setup_common_lines(h))
          lines << "Gate: #{fetch_s(h, :gate_ok).capitalize}" if fetch_s(h, :gate_ok) != ''
          lines.join("\n")
        end

        def format_smc_setup_fired(h)
          lines = ['🚀 SMC Setup Entry Fired']
          lines.concat(smc_setup_common_lines(h))
          lines << "Entry Fill: #{fetch_s(h, :entry_price)}" if fetch_s(h, :entry_price) != ''
          lines << "Size: #{fetch_s(h, :quantity)}" if fetch_s(h, :quantity) != ''
          lines.join("\n")
        end

        def format_smc_setup_invalidated(h)
          lines = ['🗑️ SMC Setup Invalidated']
          lines.concat(smc_setup_common_lines(h))
          lines << "━━━━━━━━━━━━━━━━━━━━"
          lines << "Reason: #{fetch_s(h, :reason).tr('_', ' ').capitalize}" if fetch_s(h, :reason) != ''
          if fetch_s(h, :ltp) != ''
            plain = format_decimal_plain_for_alert(fetch_s(h, :ltp))
            lines << "LTP: #{plain}" if plain != ''
          end
          lines.join("\n")
        end

        def smc_setup_common_lines(h)
          lines = []
          lines << "Setup: #{fetch_s(h, :setup_id)}" if fetch_s(h, :setup_id) != ''
          lines << "Pair: #{fetch_s(h, :pair)}" if fetch_s(h, :pair) != ''
          dir = fetch_s(h, :direction)
          dir_emoji = dir.to_s.downcase == 'long' ? '📈' : '📉'
          lines << "Bias: #{dir_emoji} #{dir.upcase}" if dir != ''
          if fetch_s(h, :entry_min) != '' && fetch_s(h, :entry_max) != ''
            lines << "Entry Zone: #{fetch_s(h, :entry_min)} - #{fetch_s(h, :entry_max)}"
          end
          lines << "Stop-Loss: #{fetch_s(h, :sl)}" if fetch_s(h, :sl) != ''
          lines << "Targets: #{fetch_s(h, :targets)}" if fetch_s(h, :targets) != ''
          lines << "Risk: #{fetch_s(h, :risk_usdt)} USDT" if fetch_s(h, :risk_usdt) != ''
          lines << "Expires: #{fetch_s(h, :expires_at)}" if fetch_s(h, :expires_at) != ''
          lines
        end

        def format_analysis_strategy_transition(h)
          lines = ['⚡ Strategy Transition']
          lines << "Pair: #{fetch_s(h, :pair)}" if fetch_s(h, :pair) != ''
          lines << "From: #{fetch_s(h, :from_action).upcase} (#{fetch_s(h, :from_reason).tr('_', ' ')})" if fetch_s(h, :from_action) != ''
          lines << "To: #{fetch_s(h, :to_action).upcase} (#{fetch_s(h, :to_reason).tr('_', ' ')})" if fetch_s(h, :to_action) != ''
          if fetch_s(h, :ltp) != ''
            plain = format_decimal_plain_for_alert(fetch_s(h, :ltp))
            lines << "LTP: #{plain}" if plain != ''
          end
          lines.join("\n")
        end

        # Avoid Float / BigDecimal scientific notation in Telegram (e.g. 0.8636e2).
        def format_decimal_plain_for_alert(raw)
          bd = BigDecimal(raw.to_s)
          bd.to_s('F')
        rescue ArgumentError, TypeError
          raw.to_s
        end

        def format_analysis_regime_change(h)
          lines = ['🌍 Regime Change']
          lines << "Pair: #{fetch_s(h, :pair)}" if fetch_s(h, :pair) != ''
          lines << "From: #{fetch_s(h, :from_label)} (State #{fetch_s(h, :from_state_id)})" if fetch_s(h, :from_label) != ''
          lines << "To: #{fetch_s(h, :to_label)} (State #{fetch_s(h, :to_state_id)})" if fetch_s(h, :to_label) != ''
          posterior = fetch_s(h, :probability_pct)
          if posterior != ''
            stab = fetch_s(h, :stability_bars)
            stab_part = stab == '' ? '' : " · stability #{stab} bars"
            lines << "Confidence: #{posterior}%#{stab_part}"
          end
          if fetch_s(h, :vol_rank) != '' && fetch_s(h, :vol_rank_total) != ''
            lines << "Volatility: #{fetch_s(h, :vol_rank)}/#{fetch_s(h, :vol_rank_total)}"
          end
          lines << "Action: #{fetch_s(h, :action).capitalize}" if fetch_s(h, :action) != ''
          lines.join("\n")
        end

        def format_analysis_regime_ai_update(h)
          lines = ['🧠 Regime AI Update']
          lines << "Current: #{fetch_s(h, :regime_label)} (Prob: #{fetch_s(h, :probability_pct)}%)" if fetch_s(h, :regime_label) != ''
          lines << "Status: #{fetch_s(h, :transition_summary).capitalize}" if fetch_s(h, :transition_summary) != ''
          lines.join("\n")
        end

        def format_analysis_price_cross(h)
          lines = ['🎯 Level Crossed']
          lines << "#{fetch_s(h, :label)}" if fetch_s(h, :label) != ''
          lines << "Pair: #{fetch_s(h, :pair)}" if fetch_s(h, :pair) != ''
          lines << "Price: #{fetch_s(h, :price)} (#{fetch_s(h, :direction).upcase})" if fetch_s(h, :price) != ''
          lines.join("\n")
        end

        def format_analysis_liquidation_proximity(h)
          lines = ['⚠️ Liquidation Warning']
          lines << "Pair: #{fetch_s(h, :pair)}" if fetch_s(h, :pair) != ''
          lines << "Distance: #{fetch_s(h, :distance_pct)}%" if fetch_s(h, :distance_pct) != ''
          lines.join("\n")
        end

        def format_fallback(type, h)
          return 'coindcx-bot (empty payload)' if h.empty?

          lines = ["Event: #{type}"]
          h.keys.sort_by(&:to_s).each do |key|
            lines << "#{key}: #{truncate_value(h[key])}"
          end
          lines.join("\n")
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
