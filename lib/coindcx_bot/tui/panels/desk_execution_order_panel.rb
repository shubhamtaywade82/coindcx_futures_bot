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
          inner_w = column_width(w)

          buf = StringIO.new
          buf << @cursor.save
          r = @row
          buf << move(r) << clear_line(top_rule(inner_w))
          r += 1
          buf << move(r) << clear_line(title_row(inner_w))
          r += 1
          buf << move(r) << clear_line(mid_rule(inner_w))
          r += 1
          h.times do |i|
            buf << move(r + i) << clear_line(data_row(exec_lines[i], ord_lines[i], inner_w))
          end
          r += h
          buf << move(r) << clear_line(bot_rule(inner_w))
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

        def column_width(total_w)
          inner = total_w - 4
          w = (inner / 2) - 1
          [w, 22].max
        end

        def move(row)
          @cursor.move_to(@col, row)
        end

        def data_row(exec_row, ord_row, inner_w)
          left = truncate_pad(format_exec_cell(exec_row), inner_w)
          right = truncate_pad(format_ord_cell(ord_row), inner_w)
          "│#{left}│#{right}│"
        end

        # Pad/truncate using visible width (ANSI-aware)
        def truncate_pad(str, w)
          return str.ljust(w) if visible_len(str) <= w

          "#{slice_visible(str, w - 1)}…".ljust(w + (str.length - visible_len(str)))
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

        def top_rule(inner_w)
          "┌#{'─' * inner_w}┬#{'─' * inner_w}┐"
        end

        def mid_rule(inner_w)
          "├#{'─' * inner_w}┼#{'─' * inner_w}┤"
        end

        def bot_rule(inner_w)
          "└#{'─' * inner_w}┴#{'─' * inner_w}┘"
        end

        def title_row(inner_w)
          l = bold('EXECUTION MATRIX'.ljust(inner_w))
          r = bold('ORDER FLOW'.ljust(inner_w))
          "│#{l}│#{r}│"
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
