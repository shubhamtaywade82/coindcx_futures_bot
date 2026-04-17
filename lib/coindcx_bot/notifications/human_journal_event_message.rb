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
