# frozen_string_literal: true

require 'tty-cursor'
require 'tty-screen'
require 'stringio'

module CoindcxBot
  module Tui
    module Panels
      # L1-style quote strip: bid/ask/spread from {TickStore} (REST RT + instrument enrich); em dash when API omits book.
      class DeskMarketDepthPanel
        # Plain header only — data rows use ANSI-aware columns (sprintf breaks width with escapes).
        HEADER = '  %-14s %8s %8s %8s %8s %7s  %-8s'

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
          now = Time.now
          rows = vm.depth_rows(now: now)
          w = [TTY::Screen.width || 80, 40].max

          buf = StringIO.new
          buf << @cursor.save
          buf << move(@row) << bold('MARKET DEPTH (L1)') << dim("  #{'─' * [w - 22, 8].max}")
          buf << move(@row + 1) << bold(format(HEADER, 'SYMBOL', 'BID', 'ASK', 'SPREAD', 'Δ%', 'AGE', 'STATE'))
          buf << move(@row + 2) << dim('─' * [w - 1, 40].max)

          @symbols.each_with_index do |_sym, idx|
            buf << move(@row + 3 + idx) << format_depth_row(rows[idx])
          end

          buf << @cursor.restore
          @output.print buf.string
          @output.flush
        end

        def row_count
          3 + @symbols.size
        end

        private

        def format_depth_row(d)
          if d.nil?
            return depth_row_line(
              dim('—'), dim('—'), dim('—'), dim('—'), dim('—'), dim('—'), dim('—')
            )
          end

          sym = d[:symbol].to_s
          sym = "#{sym[0, 12]}…" if sym.length > 13
          chg = d[:chg_pct].to_s
          chg_col = chg.start_with?('-') ? red(chg) : chg == '—' ? dim(chg) : green(chg)
          depth_row_line(
            dim(sym),
            dim(d[:bid].to_s),
            dim(d[:ask].to_s),
            dim(d[:spread].to_s),
            chg_col,
            dim(d[:age].to_s),
            colorize_state(d[:state].to_s)
          )
        end

        def depth_row_line(sym_c, bid_c, ask_c, spread_c, chg_c, age_c, state_c)
          cells = [
            fmt_cell(sym_c, 14, :left),
            fmt_cell(bid_c, 8, :right),
            fmt_cell(ask_c, 8, :right),
            fmt_cell(spread_c, 8, :right),
            fmt_cell(chg_c, 8, :right),
            fmt_cell(age_c, 7, :right),
            fmt_cell(state_c, 8, :left)
          ]
          "  #{cells[0]} #{cells[1]} #{cells[2]} #{cells[3]} #{cells[4]} #{cells[5]}  #{cells[6]}"
        end

        def fmt_cell(str, width, align)
          v = visible_len(str)
          pad = width - v
          return slice_visible(str, width) if pad.negative?

          spaces = ' ' * pad
          align == :left ? "#{str}#{spaces}" : "#{spaces}#{str}"
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

        def colorize_state(state)
          case state
          when 'LIVE' then green(state)
          when 'LAG' then yellow(state)
          else red(state)
          end
        end

        def move(row)
          @cursor.move_to(@col, row)
        end

        def bold(str)   = "\e[1m#{str}\e[0m"
        def green(str)  = "\e[32m#{str}\e[0m"
        def yellow(str) = "\e[33m#{str}\e[0m"
        def red(str)    = "\e[31m#{str}\e[0m"
        def dim(str)    = "\e[2m#{str}\e[0m"
      end
    end
  end
end
