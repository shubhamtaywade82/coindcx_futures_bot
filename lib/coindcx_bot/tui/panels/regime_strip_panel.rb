# frozen_string_literal: true

require 'tty-cursor'
require 'tty-screen'
require 'stringio'

module CoindcxBot
  module Tui
    module Panels
      # Two-line regime summary (layout.md-style) between header and futures grid.
      class RegimeStripPanel
        def initialize(engine:, origin_row:, origin_col: 0, output: $stdout)
          @engine = engine
          @row = origin_row
          @col = origin_col
          @output = output
          @cursor = TTY::Cursor
        end

        def render
          snap = @engine.snapshot
          r = normalize_regime(snap.regime)
          w = term_width
          buf = StringIO.new
          buf << @cursor.save
          buf << move(@row) << clear_line(top_rule(w))
          buf << move(@row + 1) << clear_line(line_primary(r, w))
          buf << move(@row + 2) << clear_line(line_secondary(r, w))
          buf << move(@row + 3) << clear_line(bot_rule(w))
          buf << @cursor.restore
          @output.print buf.string
          @output.flush
        end

        def row_count
          4
        end

        private

        def normalize_regime(raw)
          base = CoindcxBot::Regime::TuiState.disabled
          return base if raw.nil? || !raw.is_a?(Hash)

          base.merge(raw) { |_k, old, new| new.nil? ? old : new }
        end

        def term_width
          tw = TTY::Screen.width
          tw = tw.to_i if tw
          tw = 100 if tw.nil? || tw < 100
          tw
        end

        def top_rule(w)
          inner = w - 2
          title = ' REGIME '
          dashes = inner - title.length
          dashes = 0 if dashes.negative?
          "┌#{title}#{'─' * dashes}┐"
        end

        def bot_rule(w)
          inner = w - 2
          "└#{'─' * inner}┘"
        end

        def line_primary(r, w)
          text_w = w - 4
          prob = format_probability(r, r[:probability_pct])
          stab = format_optional_int(r, r[:stability_bars])
          conf = format_confirmed(r)
          status = (r[:status] || '—').to_s.upcase
          plain = [
            "Regime:#{r[:label]}",
            "P#{prob}",
            "Stab:#{stab}",
            "Flick:#{display_flicker(r)}",
            "Conf:#{conf}",
            status
          ].join(' ')
          box_line(plain, text_w)
        end

        def line_secondary(r, w)
          text_w = w - 4
          plain = [
            "VolRank:#{display_vol_rank(r)}",
            "A:#{display_transition(r)}",
            "HMM:#{r[:hmm_display]}"
          ].join(' ')
          dim(box_line(plain, text_w))
        end

        def standby_waiting?(r)
          r[:enabled] && !r[:active]
        end

        def format_probability(r, pct)
          return 'n/a' if standby_waiting?(r) && pct.nil?
          return '—' if pct.nil?

          format('%.0f%%', pct.to_f)
        end

        def format_optional_int(r, n)
          return 'n/a' if standby_waiting?(r) && n.nil?

          n.nil? ? '—' : n.to_s
        end

        def format_confirmed(r)
          return 'n/a' if standby_waiting?(r) && r[:confirmed].nil?
          return '—' if r[:confirmed].nil?

          r[:confirmed] ? 'YES' : 'NO'
        end

        def display_flicker(r)
          raw = r[:flicker_display]
          return 'n/a' if standby_waiting?(r) && (raw.nil? || raw.to_s == '—')

          raw.nil? || raw.to_s.empty? ? '—' : raw.to_s
        end

        def display_vol_rank(r)
          raw = r[:vol_rank_display]
          return 'n/a' if standby_waiting?(r) && (raw.nil? || raw.to_s == '—')

          raw.nil? || raw.to_s.empty? ? '—' : raw.to_s
        end

        def display_transition(r)
          raw = r[:transition_display]
          return 'n/a' if standby_waiting?(r) && (raw.nil? || raw.to_s == '—')

          raw.nil? || raw.to_s.empty? ? '—' : raw.to_s
        end

        def box_line(plain, text_w)
          line = plain.length > text_w ? "#{plain[0, text_w - 1]}…" : plain.ljust(text_w)
          "│ #{line} │"
        end

        def move(row)
          @cursor.move_to(@col, row)
        end

        def clear_line(content)
          "#{content}\e[K"
        end

        def dim(str) = "\e[2m#{str}\e[0m"
      end
    end
  end
end
