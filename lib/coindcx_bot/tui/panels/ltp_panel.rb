# frozen_string_literal: true

require 'tty-cursor'
require 'stringio'

module CoindcxBot
  module Tui
    module Panels
      class LtpPanel
        HEADER_FMT = '  %-16s %12s %10s %9s  '
        HEADER = format(HEADER_FMT, 'SYMBOL', 'LTP', 'CHG%', 'AGE')
        SEPARATOR = ('-' * HEADER.length).freeze

        def initialize(tick_store:, symbols:, origin_row:, stale_tick_seconds: 45, origin_col: 0, output: $stdout)
          @store = tick_store
          @symbols = symbols
          @row = origin_row
          @col = origin_col
          @output = output
          @cursor = TTY::Cursor
          @stale_tick_seconds = stale_tick_seconds.to_f
        end

        def render
          ticks = @store.snapshot
          now   = Time.now

          buf = StringIO.new
          buf << @cursor.save
          buf << move(@row) << bold(HEADER)
          buf << move(@row + 1) << SEPARATOR

          @symbols.each_with_index do |sym, idx|
            buf << move(@row + 2 + idx)
            buf << format_tick_row(ticks[sym], sym, now)
          end

          buf << @cursor.restore
          @output.print buf.string
          @output.flush
        end

        def row_count
          2 + @symbols.length
        end

        private

        # See StatusPanel#move — tty-cursor #move_to: pass column then row.
        def move(row)
          @cursor.move_to(@col, row)
        end

        def format_tick_row(tick, symbol, now)
          return dim(format(HEADER_FMT, symbol, '---', '---', '---')) if tick.nil?

          age_sec = (now - tick.updated_at).to_f
          stale = age_sec > @stale_tick_seconds
          chg_str = tick.change_pct ? format('%+.2f%%', tick.change_pct) : 'n/a'
          ltp_str = format('%12.2f', tick.ltp)
          ltp_colored = colorize_ltp(ltp_str, tick, stale)
          age_str = format('%.2fs', age_sec)

          line = format('  %-16s %s %10s %9s  ', symbol, ltp_colored, chg_str, age_str)
          stale ? "#{line}  [STALE]" : line
        end

        def colorize_ltp(ltp_str, tick, stale)
          return dim(ltp_str) if stale
          return red(ltp_str) if tick.change_pct&.negative?

          green(ltp_str)
        end

        def bold(str)  = "\e[1m#{str}\e[0m"
        def green(str) = "\e[32m#{str}\e[0m"
        def red(str)   = "\e[31m#{str}\e[0m"
        def dim(str)   = "\e[2m#{str}\e[0m"
      end
    end
  end
end
