# frozen_string_literal: true

require 'tty-cursor'
require 'tty-screen'
require 'stringio'
require_relative '../theme'
require_relative '../ansi_string'

module CoindcxBot
  module Tui
    module Panels
      # L1-style quote strip: bid/ask/spread from {TickStore} (REST RT + instrument enrich); em dash when API omits book.
      class DeskMarketDepthPanel
        include Theme
        include AnsiString

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
          buf << move(@row) << bold('MARKET DEPTH (L1)') << muted("  #{'─' * [w - 22, 8].max}")
          buf << move(@row + 1) << bold(format(HEADER, 'SYMBOL', 'BID', 'ASK', 'SPREAD', 'Δ%', 'AGE', 'STATE'))
          buf << move(@row + 2) << muted('─' * [w - 1, 40].max)

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
              muted('—'), muted('—'), muted('—'), muted('—'), muted('—'), muted('—'), muted('—')
            )
          end

          sym = d[:symbol].to_s
          sym = "#{sym[0, 12]}…" if sym.length > 13
          chg = d[:chg_pct].to_s
          chg_col = chg.start_with?('-') ? loss(chg) : chg == '—' ? muted(chg) : profit(chg)
          depth_row_line(
            muted(sym),
            muted(d[:bid].to_s),
            muted(d[:ask].to_s),
            muted(d[:spread].to_s),
            chg_col,
            muted(d[:age].to_s),
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

        def colorize_state(state)
          case state
          when 'LIVE' then profit(state)
          when 'LAG' then warning(state)
          else loss(state)
          end
        end

        def move(row)
          @cursor.move_to(@col, row)
        end
      end
    end
  end
end
