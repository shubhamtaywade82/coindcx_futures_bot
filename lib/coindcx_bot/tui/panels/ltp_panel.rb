# frozen_string_literal: true

require 'tty-cursor'
require 'stringio'

module CoindcxBot
  module Tui
    module Panels
      # REST/WS-derived quotes for display; engine snapshot remains authoritative for trading.
      class LtpPanel
        HEADER_FMT = '  %-14s %10s %8s %7s  %-8s'
        DATA_FMT = '  %-14s %10s %8s %7s  %-8s'

        def initialize(tick_store:, symbols:, origin_row:, stale_tick_seconds: 45, engine: nil, origin_col: 0,
                       output: $stdout)
          @store = tick_store
          @symbols = symbols
          @row = origin_row
          @col = origin_col
          @output = output
          @cursor = TTY::Cursor
          @stale_tick_seconds = stale_tick_seconds.to_f
          @engine = engine
        end

        def render
          ticks = @store.snapshot
          now   = Time.now
          w = header_width

          buf = StringIO.new
          buf << @cursor.save
          buf << move(@row) << bold("MARKET WATCH") << dim("  #{'─' * [w - 14, 12].max}")
          buf << move(@row + 1) << bold(format(HEADER_FMT, 'SYMBOL', 'LTP', 'CHG%', 'AGE', 'STATUS'))
          buf << move(@row + 2) << dim('─' * [w, 40].max)

          @symbols.each_with_index do |sym, idx|
            buf << move(@row + 3 + idx)
            buf << format_tick_row(ticks[sym], sym, now)
          end

          buf << @cursor.restore
          @output.print buf.string
          @output.flush
        end

        def row_count
          3 + @symbols.length
        end

        private

        def header_width
          # Width of header line for rule fill
          56
        end

        def move(row)
          @cursor.move_to(@col, row)
        end

        def format_tick_row(tick, symbol, now)
          return dim(format(DATA_FMT, symbol, '—', '—', '—', '—')) if tick.nil?

          age_sec = (now - tick.updated_at).to_f
          age_str = format('%.2fs', age_sec)
          ws_stale = @engine&.ws_feed_stale?(symbol)
          status = market_status(ws_stale, age_sec)
          status_s = colorize_status(status)

          chg_str = tick.change_pct ? format('%+.2f%%', tick.change_pct) : 'n/a'
          ltp_str = format('%10.2f', tick.ltp)
          ltp_colored = colorize_ltp(ltp_str, tick, ws_stale)

          format(DATA_FMT, symbol, ltp_colored, chg_str, age_str, status_s)
        end

        def market_status(ws_stale, age_sec)
          return 'STALE' if ws_stale
          return 'STALE' if age_sec > 1.0
          return 'LAG' if age_sec > 0.3

          'LIVE'
        end

        def colorize_status(status)
          case status
          when 'LIVE' then green(status)
          when 'LAG' then yellow(status)
          else red(status)
          end
        end

        def colorize_ltp(ltp_str, tick, ws_stale)
          return dim(ltp_str) if ws_stale
          return red(ltp_str) if tick.change_pct&.negative?

          green(ltp_str)
        end

        def bold(str)  = "\e[1m#{str}\e[0m"
        def green(str) = "\e[32m#{str}\e[0m"
        def red(str)   = "\e[31m#{str}\e[0m"
        def yellow(str) = "\e[33m#{str}\e[0m"
        def dim(str)   = "\e[2m#{str}\e[0m"
      end
    end
  end
end
