# frozen_string_literal: true

require 'tty-cursor'
require 'tty-screen'
require 'stringio'
require_relative '../theme'
require_relative '../ansi_string'

module CoindcxBot
  module Tui
    module Panels
      # Execution matrix (per-symbol rows) + order flow (working orders). Data from {DeskViewModel}.
      class DeskExecutionOrderPanel
        include Theme
        include AnsiString

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
          buf << move(r) << clr(top_rule(left_w, right_w))
          r += 1
          buf << move(r) << clr(title_row(left_w, right_w))
          r += 1
          buf << move(r) << clr(mid_rule(left_w, right_w))
          r += 1
          buf << move(r) << clr(header_row(left_w, right_w))
          r += 1
          h.times do |i|
            buf << move(r + i) << clr(data_row(exec_lines[i], ord_lines[i], left_w, right_w))
          end
          r += h
          buf << move(r) << clr(bot_rule(left_w, right_w))
          buf << @cursor.restore

          @output.print buf.string
          @output.flush
        end

        def row_count
          vm = DeskViewModel.build(engine: @engine, tick_store: @tick_store, symbols: @symbols)
          5 + vm.inner_height
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
          return muted('·') if row.nil?

          sym = truncate(row[:symbol].to_s, 11)
          pnl = color_pnl(row[:pnl_usdt], row[:pnl_label])
          parts = [
            warning(sym),
            muted(row[:side].to_s.ljust(5)),
            muted(row[:qty].to_s.ljust(7)),
            muted(row[:entry].to_s.ljust(7)),
            accent(row[:ltp].to_s.ljust(7)),
            pnl
          ]
          parts.join(muted(' '))
        end

        def format_ord_cell(row)
          return muted('·') if row.nil?

          lat = row[:latency] ? accent("#{row[:latency]}ms") : muted('—')
          [
            warning(row[:type_abbr].to_s.ljust(4)),
            muted(row[:symbol].to_s.ljust(12)),
            profit(row[:status].to_s.ljust(7)),
            lat
          ].join(muted(' '))
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

        def header_row(left_w, right_w)
          left = pad_or_truncate_visible(format_exec_header_line, left_w)
          right = pad_or_truncate_visible(format_ord_header_line, right_w)
          "│#{left}│#{right}│"
        end

        # Column spacing matches {#format_exec_cell} / {#format_ord_cell} (ANSI-safe pad/truncate on the row).
        def format_exec_header_line
          [
            muted('SYMBOL'.ljust(11)),
            muted('SIDE'.ljust(5)),
            muted('QTY'.ljust(7)),
            muted('ENTRY'.ljust(7)),
            muted('LTP'.ljust(7)),
            muted('PNL')
          ].join(muted(' '))
        end

        def format_ord_header_line
          [
            muted('TYPE'.ljust(4)),
            muted('PAIR'.ljust(12)),
            muted('STATUS'.ljust(7)),
            muted('LAT')
          ].join(muted(' '))
        end

        def data_row(exec_row, ord_row, left_w, right_w)
          left = pad_or_truncate_visible(format_exec_cell(exec_row), left_w)
          right = pad_or_truncate_visible(format_ord_cell(ord_row), right_w)
          "│#{left}│#{right}│"
        end

        # Pad/truncate using visible width (ANSI-aware). Ruby String#ljust counts escapes as columns.
        def pad_or_truncate_visible(str, w)
          pad_visible(str, w)
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

        def clr(content)
          "#{content}\e[K"
        end
      end
    end
  end
end
