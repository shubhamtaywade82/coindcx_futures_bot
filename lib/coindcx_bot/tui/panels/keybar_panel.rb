# frozen_string_literal: true

require 'tty-cursor'
require 'tty-screen'
require 'stringio'
require_relative '../term_width'

module CoindcxBot
  module Tui
    module Panels
      class KeybarPanel
        def initialize(origin_row:, footer_text: nil, footer_text_proc: nil, command_line_proc: nil,
                       origin_col: 0, output: $stdout)
          @row = origin_row
          @col = origin_col
          @footer_text = footer_text
          @footer_text_proc = footer_text_proc
          @command_line_proc = command_line_proc
          @output = output
          @cursor = TTY::Cursor
        end

        def render
          buf = StringIO.new
          w = [TermWidth.columns - 1, 40].max
          rule = dim('─' * w)
          foot = @footer_text_proc ? @footer_text_proc.call : @footer_text.to_s
          cmd_line = command_palette_row

          buf << @cursor.save
          buf << move(@row) << clear_line(rule)
          buf << move(@row + 1) << clear_line(controls_line_one)
          buf << move(@row + 2) << clear_line(controls_line_two)
          buf << move(@row + 3) << clear_line(dim(foot))
          buf << move(@row + 4) << clear_line(cmd_line)
          buf << @cursor.restore

          @output.print buf.string
          @output.flush
        end

        def row_count
          5
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
            keych('f', 'Flatten'),
            keych('n', 'Focus'),
            keych('/', 'Cmd')
          ].join(dim('  │  '))
        end

        def controls_line_two
          [
            "#{dim('pairs · config/bot.yml')}",
            "#{dim('Esc')} #{dim('cancel cmd')}"
          ].join(dim('  │  '))
        end

        def command_palette_row
          line = @command_line_proc&.call
          return dim("#{bold('>')} #{dim('(no command line)')}") if line.nil? || line.to_s.empty?

          line.to_s
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
