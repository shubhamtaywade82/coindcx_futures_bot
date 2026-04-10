# frozen_string_literal: true

require 'tty-cursor'
require 'tty-screen'
require 'stringio'

module CoindcxBot
  module Tui
    module Panels
      class KeybarPanel
        def initialize(origin_row:, footer_text: nil, footer_text_proc: nil, origin_col: 0, output: $stdout)
          @row = origin_row
          @col = origin_col
          @footer_text = footer_text
          @footer_text_proc = footer_text_proc
          @output = output
          @cursor = TTY::Cursor
        end

        def render
          buf = StringIO.new
          w = (TTY::Screen.width || 80) - 1
          rule = dim('─' * [[w, 40].max, 0].max)
          foot = @footer_text_proc ? @footer_text_proc.call : @footer_text.to_s

          buf << @cursor.save
          buf << move(@row) << clear_line(rule)
          buf << move(@row + 1) << clear_line(controls_line_one)
          buf << move(@row + 2) << clear_line(controls_line_two)
          buf << move(@row + 3) << clear_line(dim(foot))
          buf << @cursor.restore

          @output.print buf.string
          @output.flush
        end

        def row_count
          4
        end

        private

        def move(row)
          @cursor.move_to(@col, row)
        end

        def controls_line_one
          [
            keych('q', 'Quit'),
            keych('p', 'Pause'),
            keych('r', 'Resume'),
            keych('k', 'Kill'),
            keych('o', 'Kill off'),
            keych('f', 'Flatten')
          ].join(dim('  │  '))
        end

        def controls_line_two
          [
            "#{dim('1–2')} #{dim('symbols · bot.yml')}",
            "#{dim('m')} #{dim('mode')}",
            "#{dim('t')} #{dim('strategy (future)')}"
          ].join(dim('  │  '))
        end

        def keych(k, desc)
          "#{bold(k)}: #{dim(desc)}"
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
