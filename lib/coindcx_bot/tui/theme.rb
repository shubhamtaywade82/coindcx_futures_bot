# frozen_string_literal: true

module CoindcxBot
  module Tui
    # Centralised color palette for every TUI panel.
    #
    # Include this module in any panel class to get named color helpers:
    #
    #   include Theme
    #   green("OK")          # standard green
    #   profit("+1.23")      # semantic: green for gains
    #   loss("-0.45")        # semantic: red for losses
    #   bar_bid("███")       # depth-bar bid color
    #
    # 256-color codes are used where available for richer visual depth
    # while falling back gracefully on legacy 16-color terminals.
    module Theme
      module_function

      # ── Core ANSI (works everywhere) ────────────────────────────────
      def bold(str)           = "\e[1m#{str}\e[0m"
      def bold_magenta(str)   = "\e[1;35m#{str}\e[0m"
      def bold_red(str)       = "\e[1;31m#{str}\e[0m"
      def bold_green(str)     = "\e[1;32m#{str}\e[0m"
      def bold_cyan(str)      = "\e[1;36m#{str}\e[0m"
      def bold_yellow(str)    = "\e[1;33m#{str}\e[0m"
      def dim(str)            = "\e[2m#{str}\e[0m"
      def italic(str)         = "\e[3m#{str}\e[0m"
      def underline(str)      = "\e[4m#{str}\e[0m"
      def blink(str)          = "\e[5m#{str}\e[0m"
      def inverse(str)        = "\e[7m#{str}\e[0m"

      # Standard 16 foreground
      def green(str)   = "\e[32m#{str}\e[0m"
      def yellow(str)  = "\e[33m#{str}\e[0m"
      def red(str)     = "\e[31m#{str}\e[0m"
      def cyan(str)    = "\e[36m#{str}\e[0m"
      def magenta(str) = "\e[35m#{str}\e[0m"
      def blue(str)    = "\e[34m#{str}\e[0m"
      def white(str)   = "\e[37m#{str}\e[0m"

      # Background + foreground combos
      def on_red(str)    = "\e[41;37m#{str}\e[0m"
      def on_yellow(str) = "\e[43;30m#{str}\e[0m"
      def on_green(str)  = "\e[42;30m#{str}\e[0m"
      def on_cyan(str)   = "\e[46;30m#{str}\e[0m"

      # ── 256-color palette (richer gradients) ────────────────────────
      # fg256(n) / bg256(n) wrap a string in \e[38;5;Nm or \e[48;5;Nm.
      def fg256(n, str) = "\e[38;5;#{n}m#{str}\e[0m"
      def bg256(n, str) = "\e[48;5;#{n}m#{str}\e[0m"

      # ── Semantic colors (trading-specific) ──────────────────────────
      #
      # Use these instead of raw green/red for PnL, risk, depth —
      # one place to swap for colorblind-friendly or light-mode themes.

      def profit(str)   = "\e[38;5;48m#{str}\e[0m"   # bright green-cyan
      def loss(str)     = "\e[38;5;196m#{str}\e[0m"   # vivid red
      def neutral(str)  = "\e[38;5;246m#{str}\e[0m"   # soft gray
      def muted(str)    = "\e[2m#{str}\e[0m"           # dim
      def accent(str)   = "\e[38;5;75m#{str}\e[0m"    # steel blue
      def warning(str)  = "\e[38;5;214m#{str}\e[0m"   # amber
      def critical(str) = "\e[48;5;196;38;5;231m#{str}\e[0m"  # white on red bg

      # Depth-of-market / order book
      def bar_bid(str)  = "\e[38;5;29m#{str}\e[0m"    # deep green
      def bar_ask(str)  = "\e[38;5;124m#{str}\e[0m"   # deep red

      # ── Risk band colorizer ────────────────────────────────────────
      def color_risk_band(band)
        case band
        when 'CRIT' then on_red(" #{band} ")
        when 'HIGH' then red(band)
        when 'MED'  then yellow(band)
        else green(band)
        end
      end

      # ── PnL cell colorizer ─────────────────────────────────────────
      def color_pnl(value, label)
        return muted('—') if value.nil?

        if value.positive?
          profit(label.to_s)
        elsif value.negative?
          loss(label.to_s)
        else
          neutral(label.to_s)
        end
      end

      # ── Colored numeric (positive=green, negative=red, zero=neutral) ──
      def colored_value(v, formatted)
        return muted('—') if v.nil?

        if v.positive?
          profit(formatted)
        elsif v.negative?
          loss(formatted)
        else
          neutral(formatted)
        end
      end
    end
  end
end
