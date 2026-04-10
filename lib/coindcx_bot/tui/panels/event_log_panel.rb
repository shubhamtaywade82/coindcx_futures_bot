# frozen_string_literal: true

require 'tty-cursor'
require 'tty-screen'
require 'stringio'

module CoindcxBot
  module Tui
    module Panels
      class EventLogPanel
        def initialize(engine:, origin_row:, max_lines: 6, origin_col: 0, output: $stdout)
          @engine = engine
          @row = origin_row
          @col = origin_col
          @max_lines = max_lines
          @output = output
          @cursor = TTY::Cursor
        end

        def render
          snap = @engine.snapshot
          events = Array(snap.recent_events).last(@max_lines)
          w = (TTY::Screen.width || 80) - 2
          w = [[w, 40].max, 200].min

          buf = StringIO.new
          buf << @cursor.save
          rule = '─' * [[w - 6, 12].max, 0].max
          buf << move(@row) << clear_line("#{bold('EVENT LOG (FIFO)')} #{dim(rule)}")

          @max_lines.times do |i|
            line =
              if i < events.size
                format_event(events[i], w)
              else
                dim('·')
              end
            buf << move(@row + 1 + i) << clear_line(dim('│ ') + line)
          end

          buf << @cursor.restore
          @output.print buf.string
          @output.flush
        end

        def row_count
          1 + @max_lines
        end

        private

        def move(row)
          @cursor.move_to(@col, row)
        end

        def format_event(ev, w)
          ts = ev[:ts].to_i
          t = Time.at(ts).strftime('%H:%M:%S')
          type = ev[:type].to_s
          hint = payload_hint(ev[:payload])
          raw = "[#{t}] #{type.upcase} #{hint}".strip
          raw.length > w ? "#{raw[0, w - 1]}…" : raw
        end

        def payload_hint(pl)
          return '' unless pl.is_a?(Hash)

          pair = pl[:pair] || pl['pair']
          side = pl[:side] || pl['side']
          [pair, side].compact.map(&:to_s).join(' ')
        end

        def clear_line(content)
          "#{content}\e[K"
        end

        def bold(str) = "\e[1m#{str}\e[0m"
        def dim(str)   = "\e[2m#{str}\e[0m"
      end
    end
  end
end
