# frozen_string_literal: true

require 'tty-cursor'
require 'tty-screen'
require 'stringio'
require_relative '../term_width'
require_relative '../theme'
require_relative '../ansi_string'

module CoindcxBot
  module Tui
    module Panels
      # Regime summary between header and futures grid: two headline rows plus optional
      # wrapped lines for full AI transition + notes (+Engine#snapshot :regime +ai_*_full+).
      class RegimeStripPanel
        include Theme
        include AnsiString

        MAX_AI_DETAIL_LINES = 12

        def initialize(engine:, origin_row:, origin_col: 0, output: $stdout)
          @engine = engine
          @row = origin_row
          @col = origin_col
          @output = output
          @cursor = TTY::Cursor
        end

        def render
          if regime_feature_disabled?
            render_disabled_compact
          else
            render_full_frame
          end
        end

        def row_count
          return 1 if regime_feature_disabled?

          r = normalize_regime(@engine.snapshot.regime)
          w = term_width
          text_w = w - 4
          4 + ai_detail_wrap_lines(r, text_w).size
        end

        private

        def regime_feature_disabled?
          r = @engine.snapshot.regime
          return true unless r.is_a?(Hash)

          on = r[:enabled]
          !truthy?(on)
        end

        def render_disabled_compact
          w = term_width
          buf = StringIO.new
          buf << @cursor.save
          buf << move(@row) << clr(compact_disabled_line(w))
          buf << @cursor.restore
          @output.print buf.string
          @output.flush
        end

        def render_full_frame
          snap = @engine.snapshot
          r = normalize_regime(snap.regime)
          w = term_width
          text_w = w - 4
          detail = ai_detail_wrap_lines(r, text_w)
          buf = StringIO.new
          buf << @cursor.save
          buf << move(@row) << ui_border(top_rule(w, r))
          buf << move(@row + 1) << ui_border("│ ") << line_primary(r, w - 4) << ui_border(" │")
          buf << move(@row + 2) << ui_border("│ ") << line_secondary(r, w - 4) << ui_border(" │")
          detail.each_with_index do |plain, i|
            buf << move(@row + 3 + i) << ui_border("│ ") << ai_detail_box_line_inner(plain, text_w) << ui_border(" │")
          end
          buf << move(@row + 3 + detail.size) << ui_border(bot_rule(w))
          buf << @cursor.restore
          @output.print buf.string
          @output.flush
        end

        def compact_disabled_line(w)
          core = "#{bold('REGIME')} #{muted('off')}"
          used = visible_len(core)
          max_tail = w - used
          return core if max_tail < 4

          hint_plain = '  ·  bot.yml: regime.enabled + regime.hmm (optional AI)'
          tail_plain =
            if hint_plain.length <= max_tail
              hint_plain
            else
              "#{hint_plain[0, [max_tail - 1, 0].max]}…"
            end
          "#{core}#{muted(tail_plain)}"
        end

        def normalize_regime(raw)
          base = CoindcxBot::Regime::TuiState.disabled
          return base if raw.nil? || !raw.is_a?(Hash)

          base.merge(raw) { |_k, old, new| new.nil? ? old : new }
        end

        def term_width
          TermWidth.columns
        end

        def top_rule(w, r)
          inner = w - 2
          title = regime_box_title(r, inner)
          dashes = inner - visible_len(title)
          dashes = 0 if dashes.negative?
          "┌#{title}#{'─' * dashes}┐"
        end

        def regime_box_title(r, max_plain_len)
          core = ui_header(' REGIME ')
          sym = compact_regime_pair_label(r[:regime_pair])
          return core if sym.nil? || sym.empty?

          extra = muted(" · #{sym} ")
          full = "#{core}#{extra}"
          return full if visible_len(full) <= max_plain_len

          short_sym = sym.length > 12 ? "#{sym[0, 11]}…" : sym
          candidate = "#{core}#{muted(" · #{short_sym} ")}"
          visible_len(candidate) <= max_plain_len ? candidate : core
        end

        def compact_regime_pair_label(pair)
          p = pair.to_s.strip
          return nil if p.empty?

          p.sub(/\AB-/, '').sub(/_USDT\z/i, '')
        end

        def bot_rule(w)
          "└#{'─' * (w - 2)}┘"
        end

        def line_primary(r, w)
          s1 = "#{muted('Regime:')}#{regime_color_label(r)}"
          s2 = "#{muted('P:')}#{emerald(format_probability(r, r[:probability_pct]))}"
          s3 = "#{muted('Stab:')}#{accent(format_optional_int(r, r[:stability_bars]))}"
          s4 = "#{muted('Flick:')}#{warning(display_flicker(r))}"
          s5 = "#{muted('Conf:')}#{emerald(format_confirmed(r))}"
          s6 = "#{muted('PIPE:')}#{emerald((r[:status] || '—').to_s.upcase)}"
          parts = [s1, s2, s3, s4, s5, s6]
          join_compact(w, parts)
        end

        def line_secondary(r, w)
          s1 = "#{muted('VolRank:')}#{accent(display_vol_rank(r))}"
          s2 = "#{muted('Trans:')}#{gold(secondary_transition_cell(r))}"
          s3 = "#{muted('Mdl:')}#{accent((r[:hmm_display] || 'off').to_s)}"
          ai_cell = secondary_ai_cell(r)
          s4 = "#{muted('AI:')}#{ai_cell == 'AI:—' ? muted('—') : tag_accent(ai_cell.sub('AI:', ''))}"
          parts = [s1, s2, s3, s4]
          join_compact(w, parts)
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

        # Avoid duplicating the same copy on row 2 when wrapped +A· / +n· lines show it below.
        def secondary_transition_cell(r)
          return "A:#{display_transition(r)}" if r[:ai_transition_full].to_s.strip.empty?

          'A:↓'
        end

        def secondary_ai_cell(r)
          cell = ai_column_fragment(r[:hmm_display])
          return cell if r[:ai_notes_full].to_s.strip.empty?
          return cell if cell == 'AI:—'

          'AI:↓'
        end

        def ai_column_fragment(hmm_display)
          t = hmm_display.to_s.strip
          return 'AI:—' if t.empty?
          return 'AI:—' if t.match?(/\AAI:?\z/i)

          return t if t.match?(/\AAI[ :]/)

          "AI:#{t}"
        end

        def ai_detail_wrap_lines(r, text_w)
          out = []
          [['A· ', r[:ai_transition_full]], ['n· ', r[:ai_notes_full]]].each do |prefix, raw|
            text = raw.to_s.strip
            next if text.empty?

            chunk_w = text_w - visible_len(prefix)
            chunk_w = [[chunk_w, 8].max, 500].min
            wrap_plain_text(text, chunk_w).each do |chunk|
              break if out.size >= MAX_AI_DETAIL_LINES

              out << "#{prefix}#{chunk}"
            end
          end
          out
        end

        def wrap_plain_text(text, width)
          return [] if text.empty? || width < 8

          lines = []
          rest = text
          until rest.empty?
            if rest.length <= width
              lines << rest
              break
            end
            lines << rest[0, width]
            rest = rest[width..].lstrip
          end
          lines
        end

        def ai_detail_box_line_inner(plain, text_w)
          pad_visible(muted(plain), text_w)
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
