# frozen_string_literal: true

module CoindcxBot
  module Tui
    # ANSI-escape-aware string utilities for terminal rendering.
    #
    # Include this module in any panel class to get width-safe padding/truncation
    # that correctly ignores escape sequences when counting visible characters.
    #
    #   include AnsiString
    #   visible_len("\e[32mOK\e[0m")  # => 2
    #   pad_visible(str, 20)           # pad or truncate to 20 visible chars
    #
    module AnsiString
      ANSI_RE = /\e\[[0-9;]*m/.freeze

      module_function

      # Count visible (non-ANSI) characters.
      def visible_len(s)
        s.gsub(ANSI_RE, '').length
      end

      # Strip all ANSI escapes.
      def strip_ansi(s)
        s.to_s.gsub(ANSI_RE, '')
      end

      # Slice a string to at most +max_chars+ visible characters, preserving ANSI escapes.
      def slice_visible(s, max_chars)
        out = +''
        n = 0
        i = 0
        while i < s.length && n < max_chars
          if s[i] == "\e"
            j = s.index('m', i)
            if j
              out << s[i..j]
              i = j + 1
              next
            end
          end
          out << s[i]
          n += 1
          i += 1
        end
        out
      end

      # Pad (or truncate with trailing '…') a string to exactly +w+ visible characters.
      def pad_visible(str, w)
        v = visible_len(str)
        return "#{str}#{' ' * (w - v)}" if v < w
        return str if v == w

        "#{slice_visible(str, w - 1)}…"
      end

      # Truncate a plain string (no ANSI).
      def truncate(s, max)
        s.length <= max ? s : "#{s[0, max - 1]}…"
      end

      # Common terminal helpers
      def clear_line(content) = "#{content}\e[K"
      def move_to(cursor, col, row) = cursor.move_to(col, row)
    end
  end
end
