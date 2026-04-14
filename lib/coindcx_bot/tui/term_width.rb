# frozen_string_literal: true

require 'io/console'
require 'tty-screen'

module CoindcxBot
  module Tui
    # Single source for column count. Uses the minimum of TTY::Screen and IO.console when both exist so
    # WSL / Windows Terminal mismatches do not draw wider than the viewport (wrap corrupts box borders).
    module TermWidth
      module_function

      def columns
        tty = TTY::Screen.width
        tty = tty.to_i if tty
        cons = console_columns
        w = [tty, cons].compact.min
        w ||= tty || cons || 100
        w = 100 if w < 100
        [w, 512].min
      end

      def console_columns
        return unless IO.respond_to?(:console)

        _rows, cols = IO.console.winsize
        cols
      rescue Errno::ENODEV, IOError, NoMethodError, SystemCallError
        nil
      end
    end
  end
end
