# frozen_string_literal: true

require 'tty-cursor'
require 'tty-screen'
require 'stringio'

module CoindcxBot
  module Tui
    module Panels
      # Three-column futures desk: L2 book (focus pair) | execution + orders | risk + event log.
      class DeskFuturesGridPanel
        SIDEBAR_RESERVED = 3

        def initialize(engine:, tick_store:, order_book_store:, symbols:, focus_pair_proc:, origin_row:,
                       origin_col: 0, output: $stdout)
          @engine = engine
          @tick_store = tick_store
          @order_book_store = order_book_store
          @symbols = Array(symbols).map(&:to_s)
          @focus_pair_proc = focus_pair_proc
          @row = origin_row
          @col = origin_col
          @output = output
          @cursor = TTY::Cursor
        end

        def render
          vm = DeskViewModel.build(engine: @engine, tick_store: @tick_store, symbols: @symbols)
          h = vm.inner_height
          snap = @engine.snapshot
          focus = @focus_pair_proc&.call&.to_s || @symbols.first.to_s
          w = term_width

          left_w, mid_w, right_w = column_widths(w)
          ew, ow = execution_order_widths(mid_w)
          wide_exec = ew >= 58

          exec_rows = pad_rows(vm.execution_rows, h)
          ord_rows = pad_rows(vm.order_flow_rows, h)
          book_rows = @order_book_store.display_rows(pair: focus, max_lines: h)
          sidebar = vm.grid_sidebar_lines
          events = Array(snap.recent_events).last([h - SIDEBAR_RESERVED, 0].max)

          buf = StringIO.new
          buf << @cursor.save
          r = @row

          buf << move(r) << clear_line(outer_top_rule(left_w, mid_w, right_w))
          r += 1
          buf << move(r) << clear_line(title_row(left_w, mid_w, right_w, ew, ow, focus))
          r += 1
          buf << move(r) << clear_line(mid_rule(left_w, mid_w, right_w))
          r += 1
          buf << move(r) << clear_line(header_row(left_w, ew, ow, right_w, wide_exec: wide_exec))
          r += 1

          h.times do |i|
            left = format_book_cell(book_rows[i], left_w)
            ex = pad_visible(format_exec_cell(exec_rows[i], ew, wide_exec: wide_exec), ew)
            ord = pad_visible(format_ord_cell(ord_rows[i]), ow)
            mid = "#{ex}│#{ord}"
            right = format_sidebar_row(sidebar, events, i, h, right_w)
            buf << move(r + i) << clear_line("│#{left}│#{mid}│#{right}│")
          end

          r += h
          buf << move(r) << clear_line(outer_bot_rule(left_w, mid_w, right_w))
          buf << @cursor.restore

          @output.print buf.string
          @output.flush
        end

        def row_count
          vm = DeskViewModel.build(engine: @engine, tick_store: @tick_store, symbols: @symbols)
          5 + vm.inner_height
        end

        private

        def pad_rows(rows, h)
          out = rows.dup
          out << nil while out.size < h
          out.first(h)
        end

        def format_book_cell(row, w)
          line =
            case row
            when :empty
              dim('·')
            when Hash
              side = row[:side] == :ask ? red('A') : green('B')
              px = row[:price].to_s
              q = row[:quantity].to_s
              px = px.length > 9 ? "#{px[0, 8]}…" : px
              q = q.length > 6 ? "#{q[0, 5]}…" : q
              "#{side} #{dim(px.ljust(9))} #{dim(q.rjust(6))}"
            else
              dim('·')
            end
          pad_visible(line, w)
        end

        def format_exec_cell(row, max_visible, wide_exec:)
          return dim('·') if row.nil?

          sym = compact_pair_symbol(row[:symbol])
          if wide_exec
            line = format_exec_cell_wide(row, sym)
            line = shrink_exec_line_to_fit(row, sym) if visible_len(line) > max_visible
            line = format_exec_cell_compact(row, sym) if visible_len(line) > max_visible
            line
          else
            format_exec_cell_compact(row, sym)
          end
        end

        def format_exec_cell_wide(row, sym)
          lst = (row[:last] || row[:ltp]).to_s
          mrk = row[:mark].to_s
          side = row[:side].to_s.upcase
          side = side[0, 5].ljust(5) if side.length > 5
          side = side.ljust(5)
          [
            yellow(truncate(sym, 6).ljust(6)),
            dim(side),
            dim(format_exec_qty(row[:qty], 10).ljust(10)),
            dim(row[:entry].to_s.ljust(8)),
            cyan(lst.ljust(8)),
            dim(mrk.ljust(8)),
            dim(row[:sl].to_s.ljust(7)),
            format_pnl_cell(row[:pnl_usdt], row[:pnl_label])
          ].join(dim(' '))
        end

        def format_exec_cell_compact(row, sym)
          mrk = row[:mark].to_s
          px = mrk.strip.empty? || mrk == '—' ? (row[:last] || row[:ltp]).to_s : mrk
          [
            yellow(truncate(sym, 5).ljust(5)),
            dim(side_abbrev(row[:side])),
            dim(format_exec_qty(row[:qty], 9).ljust(9)),
            dim(row[:entry].to_s.ljust(7)),
            dim(px.ljust(8)),
            format_pnl_cell(row[:pnl_usdt], pnl_short_label(row))
          ].join(dim(' '))
        end

        def shrink_exec_line_to_fit(row, sym)
          lst = (row[:last] || row[:ltp]).to_s
          mrk = row[:mark].to_s
          side = row[:side].to_s.upcase
          side = side[0, 5].ljust(5)
          [
            yellow(truncate(sym, 6).ljust(6)),
            dim(side),
            dim(format_exec_qty(row[:qty], 10).ljust(10)),
            dim(row[:entry].to_s.ljust(8)),
            cyan(lst.ljust(8)),
            dim(mrk.ljust(8)),
            dim(row[:sl].to_s.ljust(7)),
            format_pnl_cell(row[:pnl_usdt], pnl_short_label(row))
          ].join(dim(' '))
        end

        def pnl_short_label(row)
          u = row[:pnl_usdt]
          return '—' if u.nil?

          format('%+.2f', u.to_f)
        end

        def compact_pair_symbol(pair)
          pair.to_s.sub(/^B-/, '').sub(/_USDT\z/i, '')
        end

        def side_abbrev(side)
          s = side.to_s.downcase
          return '·' if s == 'flat'

          return 'L' if %w[long buy].include?(s)
          return 'S' if %w[short sell].include?(s)

          side.to_s[0] || '·'
        end

        def format_exec_qty(raw, max_chars)
          s = raw.to_s
          return '—' if s.strip.empty? || s == '—'
          return s if s.length <= max_chars

          f = Float(s)
          if f.abs >= 100_000
            t = format('%.2e', f)
          elsif f.abs >= 1000
            t = format('%.2f', f)
          else
            t = format('%.6g', f)
          end
          t = t[0, max_chars]
          t.length < s.length ? t : s[0, max_chars]
        rescue ArgumentError, TypeError
          truncate(s, max_chars)
        end

        def format_ord_cell(row)
          return dim('·') if row.nil?

          lat = row[:latency] ? cyan("#{row[:latency]}ms") : dim('—')
          [
            yellow(row[:type_abbr].to_s.ljust(3)),
            dim(truncate(row[:symbol].to_s, 9).ljust(9)),
            green(row[:status].to_s[0, 3].ljust(3)),
            lat
          ].join(dim(' '))
        end

        def format_sidebar_row(sidebar, events, i, h, w)
          text =
            if i < SIDEBAR_RESERVED
              sidebar[i] || dim('·')
            else
              ev_i = i - SIDEBAR_RESERVED
              if ev_i < events.size
                format_event(events[ev_i], w)
              else
                dim('·')
              end
            end
          pad_visible(text, w)
        end

        def format_event(ev, w)
          ts = ev[:ts].to_i
          t = Time.at(ts).strftime('%H:%M:%S')
          type = ev[:type].to_s
          hint = payload_hint(ev[:payload])
          raw = "#{t} #{type[0, 8]} #{hint}".strip
          raw.length > w ? "#{raw[0, w - 1]}…" : raw
        end

        def payload_hint(pl)
          return '' unless pl.is_a?(Hash)

          pair = pl[:pair] || pl['pair']
          bits = [pair].compact.map(&:to_s)
          oc = pl[:outcome] || pl['outcome']
          bits << oc.to_s if oc.to_s.strip != ''
          bits.join(' ')
        end

        def term_width
          tw = TTY::Screen.width
          tw = tw.to_i if tw
          tw = 100 if tw.nil? || tw < 100
          tw
        end

        def column_widths(total_w)
          inner = [total_w - 4, 60].max
          # Favor a wider center column so positions + orders stay readable.
          right = (inner * 0.24).to_i.clamp(20, 44)
          left = (inner * 0.20).to_i.clamp(18, 30)
          mid = inner - left - right
          if mid < 30
            mid = 30
            left = [inner - mid - right, 18].max
            right = inner - left - mid
            right = [right, 20].max
            left = inner - mid - right
          end
          [left, mid, right]
        end

        # Split middle column: positions need more width than the order strip.
        def execution_order_widths(mid_w)
          inner = [mid_w - 1, 18].max
          ow = (inner * 0.28).to_i.clamp(18, 26)
          ew = inner - ow
          if ew < 34
            ow = [inner - 34, 16].max
            ew = inner - ow
          end
          [ew, ow]
        end

        def outer_top_rule(lw, mw, rw)
          "┌#{'─' * lw}┬#{'─' * mw}┬#{'─' * rw}┐"
        end

        def outer_bot_rule(lw, mw, rw)
          "└#{'─' * lw}┴#{'─' * mw}┴#{'─' * rw}┘"
        end

        def mid_rule(lw, mw, rw)
          "├#{'─' * lw}┼#{'─' * mw}┼#{'─' * rw}┤"
        end

        def title_row(lw, mw, rw, ew, ow, focus)
          fp = truncate(focus.to_s, 10)
          l = bold(pad_plain("BOOK #{fp}", lw))
          m = "#{pad_visible(bold('POSITIONS'), ew)}│#{pad_visible(bold('ORDERS'), ow)}"
          m = pad_visible(m, mw)
          r = bold(pad_plain('RISK · LOG', rw))
          "│#{l}│#{m}│#{r}│"
        end

        def header_row(lw, ew, ow, rw, wide_exec:)
          lh = [dim('S'), dim('PRICE'.ljust(8)), dim('QTY'.rjust(6))].join(dim(' '))
          eh =
            if wide_exec
              [
                dim('SYM'.ljust(6)),
                dim('SIDE'.ljust(5)),
                dim('QTY'.ljust(10)),
                dim('ENT'.ljust(8)),
                dim('LAST'.ljust(8)),
                dim('MARK'.ljust(8)),
                dim('SL'.ljust(7)),
                dim('PNL')
              ].join(dim(' '))
            else
              [
                dim('SYM'.ljust(5)),
                dim('S'),
                dim('QTY'.ljust(9)),
                dim('ENT'.ljust(7)),
                dim('MARK'.ljust(8)),
                dim('PNL')
              ].join(dim(' '))
            end
          oh = [
            dim('T'.ljust(3)),
            dim('PAIR'.ljust(9)),
            dim('ST'.ljust(3)),
            dim('LAT')
          ].join(dim(' '))
          rh = dim('EVENTS')
          "│#{pad_visible(lh, lw)}│#{pad_visible(eh, ew)}│#{pad_visible(oh, ow)}│#{pad_visible(rh, rw)}│"
        end

        def pad_plain(text, w)
          t = text.length > w ? "#{text[0, [w - 1, 0].max]}…" : text
          t.ljust(w)
        end

        def format_pnl_cell(u, label)
          return dim('—') if u.nil?

          u.positive? ? green(label.to_s) : u.negative? ? red(label.to_s) : yellow(label.to_s)
        end

        def pad_visible(str, w)
          v = visible_len(str)
          return "#{str}#{' ' * (w - v)}" if v < w
          return str if v == w

          "#{slice_visible(str, w - 1)}…"
        end

        def visible_len(s)
          s.gsub(/\e\[[0-9;]*m/, '').length
        end

        def slice_visible(s, max_chars)
          out = +''
          n = 0
          i = 0
          while i < s.length && n < max_chars
            if s[i] == "\e"
              j = s.index('m', i)
              if j
                out << s[i..j]
                i = j + 1
                next
              end
            end
            out << s[i]
            n += 1
            i += 1
          end
          out
        end

        def truncate(s, max)
          s.length <= max ? s : "#{s[0, max - 1]}…"
        end

        def move(row)
          @cursor.move_to(@col, row)
        end

        def clear_line(content)
          "#{content}\e[K"
        end

        def bold(str)   = "\e[1m#{str}\e[0m"
        def green(str)  = "\e[32m#{str}\e[0m"
        def yellow(str) = "\e[33m#{str}\e[0m"
        def red(str)    = "\e[31m#{str}\e[0m"
        def cyan(str)   = "\e[36m#{str}\e[0m"
        def dim(str)    = "\e[2m#{str}\e[0m"
      end
    end
  end
end
