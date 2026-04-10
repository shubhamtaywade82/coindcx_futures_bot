# frozen_string_literal: true

require 'tty-cursor'
require 'tty-screen'
require 'stringio'

module CoindcxBot
  module Tui
    module Panels
      # Execution matrix (per-symbol rows) + order flow (working orders). Data from {DeskViewModel}.
      class DeskExecutionOrderPanel
        def initialize(engine:, tick_store:, symbols:, origin_row:, origin_col: 0, output: $stdout)
          @engine = engine
          @tick_store = tick_store
          @symbols = Array(symbols).map(&:to_s)
          @row = origin_row
          @col = origin_col
          @output = output
          @cursor = TTY::Cursor
        end

        def render
          vm = DeskViewModel.build(engine: @engine, tick_store: @tick_store, symbols: @symbols)
          h = vm.inner_height
          exec_lines = pad_execution(vm.execution_rows, h)
          ord_lines = pad_orders(vm.order_flow_rows, h)

          w = term_width
          left_w, right_w = column_widths(w)

          buf = StringIO.new
          buf << @cursor.save
          r = @row
          buf << move(r) << clear_line(top_rule(left_w, right_w))
          r += 1
          buf << move(r) << clear_line(title_row(left_w, right_w))
          r += 1
          buf << move(r) << clear_line(mid_rule(left_w, right_w))
          r += 1
          h.times do |i|
            buf << move(r + i) << clear_line(data_row(exec_lines[i], ord_lines[i], left_w, right_w))
          end
          r += h
          buf << move(r) << clear_line(bot_rule(left_w, right_w))
          buf << @cursor.restore

          @output.print buf.string
          @output.flush
        end

        def row_count
          vm = DeskViewModel.build(engine: @engine, tick_store: @tick_store, symbols: @symbols)
          4 + vm.inner_height
        end

        private

        def pad_execution(rows, h)
          out = rows.dup
          out << nil while out.size < h
          out.first(h)
        end

        def pad_orders(rows, h)
          out = rows.dup
          out << nil while out.size < h
          out.first(h)
        end

        def format_exec_cell(row)
          return dim('·') if row.nil?

          sym = truncate(row[:symbol].to_s, 11)
          pnl = format_pnl_cell(row[:pnl_usdt], row[:pnl_label])
          parts = [
            yellow(sym),
            dim(row[:side].to_s.ljust(5)),
            dim(row[:qty].to_s.ljust(7)),
            dim(row[:entry].to_s.ljust(7)),
            cyan(row[:ltp].to_s.ljust(7)),
            pnl
          ]
          parts.join(dim(' '))
        end

        def format_pnl_cell(u, label)
          return dim('—') if u.nil?

          u.positive? ? green(label.to_s) : u.negative? ? red(label.to_s) : yellow(label.to_s)
        end

        def format_ord_cell(row)
          return dim('·') if row.nil?

          lat = row[:latency] ? cyan("#{row[:latency]}ms") : dim('—')
          [
            yellow(row[:type_abbr].to_s.ljust(4)),
            dim(row[:symbol].to_s.ljust(12)),
            green(row[:status].to_s.ljust(7)),
            lat
          ].join(dim(' '))
        end

        def term_width
          w = TTY::Screen.width
          w = w.to_i if w
          w = 80 if w.nil? || w < 40
          w
        end

        # Full row: │ left │ right │  => left + right + 3 == total_w (handles odd widths).
        def column_widths(total_w)
          content = [total_w - 3, 4].max
          left = content / 2
          right = content - left
          [left, right]
        end

        def move(row)
          @cursor.move_to(@col, row)
        end

        def data_row(exec_row, ord_row, left_w, right_w)
          left = pad_or_truncate_visible(format_exec_cell(exec_row), left_w)
          right = pad_or_truncate_visible(format_ord_cell(ord_row), right_w)
          "│#{left}│#{right}│"
        end

        # Pad/truncate using visible width (ANSI-aware). Ruby String#ljust counts escapes as columns.
        def pad_or_truncate_visible(str, w)
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

        def top_rule(left_w, right_w)
          "┌#{'─' * left_w}┬#{'─' * right_w}┐"
        end

        def mid_rule(left_w, right_w)
          "├#{'─' * left_w}┼#{'─' * right_w}┤"
        end

        def bot_rule(left_w, right_w)
          "└#{'─' * left_w}┴#{'─' * right_w}┘"
        end

        def title_row(left_w, right_w)
          l = bold(pad_plain_title('EXECUTION MATRIX', left_w))
          r = bold(pad_plain_title('ORDER FLOW', right_w))
          "│#{l}│#{r}│"
        end

        def pad_plain_title(text, w)
          t = text.length > w ? "#{text[0, [w - 1, 0].max]}…" : text
          t.ljust(w)
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
