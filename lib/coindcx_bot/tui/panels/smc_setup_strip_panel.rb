# frozen_string_literal: true

require 'tty-cursor'
require 'stringio'
require_relative '../term_width'
require_relative '../theme'
require_relative '../ansi_string'

module CoindcxBot
  module Tui
    module Panels
      # SMC TradeSetup planner (Ollama) + active FSM rows — separate from REGIME strip (HMM / regime.ai).
      class SmcSetupStripPanel
        include Theme
        include AnsiString

        TRADE_SETUP_STATE_ABBREV = {
          'pending_sweep' => 'P_SW',
          'sweep_seen' => 'SW_S',
          'awaiting_confirmations' => 'AW_CF',
          'armed_entry' => 'ARMED',
          'active' => 'LIVE',
          'completed' => 'DONE',
          'invalidated' => 'INV'
        }.freeze

        SETUP_UUID_RE = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i.freeze

        def initialize(engine:, origin_row:, origin_col: 0, output: $stdout)
          @engine = engine
          @row = origin_row
          @col = origin_col
          @output = output
          @cursor = TTY::Cursor
        end

        def render
          snap = @engine.snapshot
          s = snap.smc_setup
          s = SmcSetup::TuiOverlay::DISABLED if s.nil? || !s.is_a?(Hash)

          buf = StringIO.new
          buf << @cursor.save
          if !truthy?(s[:enabled])
            buf << move(@row) << clr(line_off(term_width))
            buf << @cursor.restore
            @output.print buf.string
            @output.flush
            return
          end

          w = term_width
          buf << move(@row) << ui_border("┌─") << ui_header(" SMC SETUP ") << ui_border("#{'─' * (w - 14)}┐")
          buf << move(@row + 1) << ui_border("│ ") << line_planner(s, w - 4) << ui_border(" │")
          buf << move(@row + 2) << ui_border("│ ") << line_setups(s, w - 4) << ui_border(" │")
          buf << move(@row + 3) << ui_border("└#{'─' * (w - 2)}┘")

          buf << @cursor.restore
          @output.print buf.string
          @output.flush
        end

        def row_count
          s = @engine.snapshot.smc_setup
          s = SmcSetup::TuiOverlay::DISABLED if s.nil? || !s.is_a?(Hash)
          truthy?(s[:enabled]) ? 4 : 1
        end

        private

        def term_width
          TermWidth.columns
        end

        def line_off(w)
          colored = "#{bold('SMC·SETUP')} #{muted('off')}  #{muted('·')}  #{muted('bot.yml smc_setup.enabled')}"
          p = strip_ansi(colored)
          return colored if p.length <= w

          "#{p[0, w - 1]}…"
        end

        def line_planner(s, w)
          plan_on = truthy?(s[:planner_enabled])
          plan_s = plan_on ? tag_live('PLANNER·ON') : tag_neutral('PLANNER·OFF')
          gk = truthy?(s[:gatekeeper_enabled]) ? tag_warning('GK·ON') : tag_neutral('GK·OFF')
          ax = truthy?(s[:auto_execute]) ? tag_accent('AUTO·EXE') : tag_neutral('AUTO·OFF')
          last = muted(format_last_run(s[:planner_last_at], s[:planner_interval_s]))
          err = s[:planner_error].to_s.strip
          err_part = err.empty? ? nil : loss("ERR: #{err[0, 120]}")
          colored = [plan_s, gk, ax, last, err_part].compact.join('  ')
          p = strip_ansi(colored)
          return colored if p.length <= w

          "#{p[0, w - 1]}…"
        end

        def line_setups(s, w)
          rows = Array(s[:active_setups])
          if rows.empty?
            plain = '(no active TradeSetups — wait for planner or: bin/bot smc-setup plan-once)'
            t = plain.length > w ? "#{plain[0, w - 1]}…" : plain
            return muted(t)
          end

          total = s[:active_count].to_i
          total = rows.size if total < rows.size

          colored = fit_active_setups_line(rows, total, w)
          return colored if visible_len(colored) <= w

          pad_visible(colored, w)
        end

        def fit_active_setups_line(rows, total_count, w)
          cap = [rows.size, 5].min
          cap.downto(1) do |n|
            slice = rows.first(n)
            extra = active_overflow_suffix(total_count, n)
            [24, 20, 16, 14, 12, 10, 8, 6].each do |id_max|
              plain = plain_active_line(slice, extra, id_max)
              next if plain.length > w

              return colored_active_line(slice, extra, id_max)
            end
          end

          slice = rows.first(1)
          extra = active_overflow_suffix(total_count, 1)
          colored_active_line(slice, extra, 6)
        end

        def active_overflow_suffix(total_count, shown)
          return '' if total_count <= shown

          " +#{total_count - shown}"
        end

        def plain_active_line(slice, extra, id_max)
          parts = slice.map { |r| format_active_setup_segment_plain(r, id_max) }
          "ACTIVE: #{parts.join(' | ')}#{extra}"
        end

        def colored_active_line(slice, extra, id_max)
          parts = slice.map { |r| format_active_setup_segment_plain(r, id_max) }
          "#{bold('ACTIVE:')} #{parts.join(muted(' | '))}#{muted(extra)}"
        end

        def format_active_setup_segment_plain(row, id_max)
          gid = format_trade_setup_id((row[:setup_id] || row['setup_id']).to_s, max_chars: id_max)
          pair = (row[:pair] || row['pair']).to_s.sub(/\AB-/, '')
          st = abbreviate_trade_setup_state((row[:state] || row['state']).to_s)
          dir = (row[:direction] || row['direction']).to_s[0, 1].upcase
          "#{pair}·#{gid}·#{st}·#{dir}"
        end

        def abbreviate_trade_setup_state(state)
          key = state.strip
          return '—' if key.empty?

          TRADE_SETUP_STATE_ABBREV.fetch(key.downcase) do
            k = key
            return k.upcase if k.length <= 6

            "#{k[0, 5]}~"
          end
        end

        def format_trade_setup_id(raw, max_chars:)
          s = raw.to_s.strip
          return '—' if s.empty?
          return s[0, 8] if s.match?(SETUP_UUID_RE)

          return s if s.length <= max_chars

          tail = 4
          head = max_chars - 1 - tail
          return "#{s[0, max_chars - 1]}…" if head < 1

          "#{s[0, head]}…#{s[-tail, tail]}"
        end

        def format_last_run(at, interval_s)
          return 'LAST: —' if at.nil?

          sec = (Time.now - at).to_i
          return 'LAST: just now' if sec < 5

          if sec < 120
            "LAST: #{sec}s ago"
          else
            "LAST: #{(sec / 60).round}m ago (Δ#{interval_s.to_i}s)"
          end
        end

        def move(row)
          @cursor.move_to(@col, row)
        end

        def clr(content)
          "\e[0m#{content}\e[K"
        end
      end
    end
  end
end
