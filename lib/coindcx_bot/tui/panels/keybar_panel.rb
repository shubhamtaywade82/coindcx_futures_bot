# frozen_string_literal: true

require 'tty-cursor'
require 'tty-screen'
require 'stringio'
require_relative '../term_width'
require_relative '../theme'

module CoindcxBot
  module Tui
    module Panels
      class KeybarPanel
        include Theme

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
          rule = muted('─' * w)
          foot = @footer_text_proc ? @footer_text_proc.call : @footer_text.to_s
          cmd_line = command_palette_row

          buf << @cursor.save
          buf << move(@row) << clr(rule)
          buf << move(@row + 1) << clr(controls_line_one)
          buf << move(@row + 2) << clr(controls_line_two)
          buf << move(@row + 3) << clr(muted(foot))
          buf << move(@row + 4) << clr(cmd_line)
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
          ].join(muted('  │  '))
        end

        def controls_line_two
          [
            "#{muted('pairs · config/bot.yml')}",
            "#{muted('Esc')} #{muted('cancel cmd')}"
          ].join(muted('  │  '))
        end

        def command_palette_row
          line = @command_line_proc&.call
          return muted("#{bold('>')} #{muted('(no command line)')}") if line.nil? || line.to_s.empty?

          line.to_s
        end

        def keych(k, desc)
          "#{bold(k)}: #{muted(desc)}"
        end

        def clr(content)
          "#{content}\e[K"
        end
      end
    end
  end
end
