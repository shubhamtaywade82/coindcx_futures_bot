# frozen_string_literal: true

require 'io/console'
require 'tty-screen'

module CoindcxBot
  module Tui
    # Single source for row count.
    module TermHeight
      module_function

      def rows
        tty = TTY::Screen.height
        tty = tty.to_i if tty
        cons = console_rows
        h = [tty, cons].compact.min
        h ||= tty || cons || 28
        h = 28 if h < 28
        [h, 512].min
      end

      def console_rows
        return unless IO.respond_to?(:console)

        rows, _cols = IO.console.winsize
        rows
      rescue Errno::ENODEV, IOError, NoMethodError, SystemCallError
        nil
      end
    end
  end
end
