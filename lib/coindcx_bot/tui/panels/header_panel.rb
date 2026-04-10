# frozen_string_literal: true

require 'tty-cursor'
require 'stringio'

module CoindcxBot
  module Tui
    module Panels
      # Top status strip: mode / time / WS / latency, engine / kill / feed / errors, PnL row.
      class HeaderPanel
        def initialize(engine:, origin_row: 0, origin_col: 0, output: $stdout)
          @engine = engine
          @row = origin_row
          @col = origin_col
          @output = output
          @cursor = TTY::Cursor
        end

        def render
          snap = @engine.snapshot
          w = term_width

          buf = StringIO.new
          buf << @cursor.save
          buf << move(@row)     << clear_line(line_mode_time_ws_lat(snap, w))
          buf << move(@row + 1) << clear_line(line_engine_kill_feed_err(snap, w))
          buf << move(@row + 2) << clear_line(line_balance_pnl(snap, w))
          buf << move(@row + 3) << clear_line(dim('─' * [[w - 1, 40].max, 120].min))
          buf << @cursor.restore

          @output.print buf.string
          @output.flush
        end

        def row_count
          4
        end

        private

        def term_width
          TTY::Screen.width || 80
        end

        def move(row)
          @cursor.move_to(@col, row)
        end

        def line_mode_time_ws_lat(snap, w)
          mode = snap.dry_run ? bold_magenta('PAPER') : bold_red('LIVE')
          t = Time.now.strftime('%Y-%m-%d %H:%M:%S')
          ws =
            if snap.stale
              red('WS: ○ STALE')
            else
              green('WS: ● CONNECTED')
            end
          lat =
            if snap.ws_last_tick_ms_ago
              dim('LAT: ') + cyan("#{snap.ws_last_tick_ms_ago}ms")
            else
              dim('LAT: —')
            end
          join_compact(w, ["MODE: #{mode}", "TIME: #{t}", ws, lat])
        end

        def line_engine_kill_feed_err(snap, w)
          eng =
            if snap.running
              green('ENGINE: RUN')
            else
              red('ENGINE: STOP')
            end
          pause = snap.paused ? on_yellow(' PAUSED ') : nil
          kill = snap.kill_switch ? on_red(' KILL: ON ') : dim('KILL: OFF')
          feed = snap.stale ? on_yellow(' FEED: STALE ') : green(' FEED: OK ')
          err = snap.last_error ? red(truncate(snap.last_error.to_s, 28)) : dim('ERR: NONE')
          join_compact(w, [eng, pause, kill, feed, err].compact)
        end

        def line_balance_pnl(snap, w)
          bal =
            if snap.capital_inr
              bold('BAL: ') + dim('₹') + fmt_inr(snap.capital_inr)
            else
              dim('BAL: —')
            end
          pnl = bold('PnL: ') + bold_cyan(fmt_inr(snap.daily_pnl))
          rest =
            if paper_metrics?(snap)
              pm = snap.paper_metrics
              [
                "#{bold('REAL: ')}#{fmt_num(pm[:total_realized_pnl])}",
                "#{bold('UNREAL: ')}#{yellow(fmt_num(pm[:unrealized_pnl]))}",
                "#{bold('FEES: ')}#{dim(fmt_num(pm[:total_fees]))}"
              ].join(dim(' │ '))
            else
              [dim('REAL: —'), dim('UNREAL: —'), dim('FEES: —')].join(dim(' │ '))
            end
          join_compact(w, [bal, pnl, rest])
        end

        def join_compact(_w, parts)
          parts.join(dim(' │ '))
        end

        def paper_metrics?(snap)
          snap.paper_metrics.is_a?(Hash) && snap.paper_metrics.any?
        end

        def fmt_inr(v)
          format('₹%.2f', BigDecimal(v.to_s))
        rescue ArgumentError, TypeError
          '₹0.00'
        end

        def fmt_num(v)
          format('%.2f', BigDecimal((v || 0).to_s))
        rescue ArgumentError, TypeError
          '0.00'
        end

        def truncate(s, max)
          s.length <= max ? s : "#{s[0, max - 1]}…"
        end

        def clear_line(content)
          "#{content}\e[K"
        end

        def bold(str)           = "\e[1m#{str}\e[0m"
        def bold_cyan(str)      = "\e[1;36m#{str}\e[0m"
        def bold_magenta(str)   = "\e[1;35m#{str}\e[0m"
        def bold_red(str)       = "\e[1;31m#{str}\e[0m"
        def cyan(str)           = "\e[36m#{str}\e[0m"
        def green(str)          = "\e[32m#{str}\e[0m"
        def yellow(str)         = "\e[33m#{str}\e[0m"
        def red(str)            = "\e[31m#{str}\e[0m"
        def dim(str)            = "\e[2m#{str}\e[0m"
        def on_yellow(str)      = "\e[43;30m#{str}\e[0m"
        def on_red(str)         = "\e[41;37m#{str}\e[0m"
      end
    end
  end
end
