# frozen_string_literal: true

require 'tty-cursor'
require 'stringio'

module CoindcxBot
  module Tui
    module Panels
      class StatusPanel
        def initialize(engine:, origin_row: 0, origin_col: 0, output: $stdout)
          @engine = engine
          @row    = origin_row
          @col    = origin_col
          @output = output
          @cursor = TTY::Cursor
          @frame  = 0
        end

        def render
          @frame += 1
          snap = @engine.snapshot

          buf = StringIO.new
          buf << @cursor.save
          buf << move(@row)     << mode_line(snap)
          buf << move(@row + 1) << status_line(snap)
          buf << move(@row + 2) << metrics_line(snap)
          buf << @cursor.restore

          @output.print buf.string
          @output.flush
        end

        def row_count
          3
        end

        private

        def move(row)
          @cursor.move_to(row, @col)
        end

        def mode_line(snap)
          mode = snap.dry_run ? inverse_magenta('  DRY RUN  ') : inverse_red('  LIVE  ')
          time = dim(Time.now.strftime('%Y-%m-%d %H:%M:%S'))
          frame_info = dim("frame ##{@frame}")
          clear_line("#{mode}  #{time}  #{frame_info}")
        end

        def status_line(snap)
          parts = []
          parts << (snap.running ? "#{green('●')} Engine" : "#{red('●')} Stopped")
          parts << (snap.paused ? on_yellow(' PAUSED ') : dim(' run '))
          parts << (snap.kill_switch ? on_red(' KILL ') : dim(' kill·off '))
          parts << feed_status(snap)
          clear_line(parts.join(dim(' │ ')))
        end

        def feed_status(snap)
          stale_sec = snap.stale_tick_seconds || 45
          if snap.stale
            on_yellow(" STALE (>#{stale_sec}s) ")
          else
            green(' feed·ok ')
          end
        end

        def metrics_line(snap)
          pnl = bold_cyan("₹#{snap.daily_pnl.to_s('F')}")
          err = snap.last_error ? red(snap.last_error.to_s[0, 60]) : dim('none')
          clear_line("#{bold('PnL today')} #{pnl}  #{dim('·')}  #{bold('last_error')} #{err}")
        end

        def clear_line(content)
          "#{content}\e[K"
        end

        def bold(str)           = "\e[1m#{str}\e[0m"
        def bold_cyan(str)      = "\e[1;36m#{str}\e[0m"
        def green(str)          = "\e[32m#{str}\e[0m"
        def red(str)            = "\e[31m#{str}\e[0m"
        def dim(str)            = "\e[2m#{str}\e[0m"
        def on_yellow(str)      = "\e[43;30m#{str}\e[0m"
        def on_red(str)         = "\e[41;37m#{str}\e[0m"
        def inverse_magenta(str) = "\e[7;35;1m#{str}\e[0m"
        def inverse_red(str)    = "\e[7;31;1m#{str}\e[0m"
      end
    end
  end
end
