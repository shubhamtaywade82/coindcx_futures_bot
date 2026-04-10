# frozen_string_literal: true

require 'tty-cursor'
require 'tty-screen'
require 'stringio'

module CoindcxBot
  module Tui
    module Panels
      # L1-style quote strip: bid/ask/spread require exchange depth (not wired) — shown as em dash; Δ%/AGE/STATE live.
      class DeskMarketDepthPanel
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
          return dim(format(HEADER, '—', '—', '—', '—', '—', '—', '—')) if d.nil?

          sym = d[:symbol].to_s
          sym = "#{sym[0, 12]}…" if sym.length > 13
          chg = d[:chg_pct].to_s
          chg_col = chg.start_with?('-') ? red(chg) : chg == '—' ? dim(chg) : green(chg)
          format(
            HEADER,
            sym,
            dim(d[:bid].to_s),
            dim(d[:ask].to_s),
            dim(d[:spread].to_s),
            chg_col,
            dim(d[:age].to_s),
            colorize_state(d[:state].to_s)
          )
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
