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
          ew = (mid_w - 1) / 2
          ow = mid_w - 1 - ew

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
          buf << move(r) << clear_line(header_row(left_w, ew, ow, right_w))
          r += 1

          h.times do |i|
            left = format_book_cell(book_rows[i], left_w)
            ex = pad_visible(format_exec_cell(exec_rows[i]), ew)
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

        def format_exec_cell(row)
          return dim('·') if row.nil?

          sym = truncate(row[:symbol].to_s, 8)
          lst = (row[:last] || row[:ltp]).to_s
          mrk = row[:mark].to_s
          parts = [
            yellow(sym),
            dim(row[:side].to_s[0, 4].ljust(4)),
            dim(row[:qty].to_s.ljust(4)),
            dim(row[:entry].to_s.ljust(6)),
            cyan(lst.ljust(6)),
            dim(mrk.ljust(6)),
            dim(row[:sl].to_s.ljust(5)),
            format_pnl_cell(row[:pnl_usdt], row[:pnl_label])
          ]
          parts.join(dim(' '))
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
          right = (inner * 0.30).to_i.clamp(24, 48)
          left = (inner * 0.24).to_i.clamp(22, 34)
          mid = inner - left - right
          if mid < 30
            mid = 30
            left = [inner - mid - right, 20].max
            right = inner - left - mid
            right = [right, 22].max
            left = inner - mid - right
          end
          [left, mid, right]
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

        def header_row(lw, ew, ow, rw)
          lh = [dim('S'), dim('PRICE'.ljust(8)), dim('QTY'.rjust(6))].join(dim(' '))
          eh = [
            dim('SYM'.ljust(8)),
            dim('SD'.ljust(4)),
            dim('QTY'.ljust(4)),
            dim('ENT'.ljust(6)),
            dim('LAST'.ljust(6)),
            dim('MARK'.ljust(6)),
            dim('SL'.ljust(5)),
            dim('PNL')
          ].join(dim(' '))
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
