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
      
      def truthy?(v)
        v == true || v.to_s.downcase == 'true' || v.to_s == '1'
      end

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

      # ── Premium Tokens ──────────────────────────────────────────────
      def slate(str)     = fg256(244, str)
      def steel(str)     = fg256(67, str)
      def gold(str)      = fg256(220, str)
      def sapphire(str)  = fg256(33, str)
      def emerald(str)   = fg256(48, str)
      def ruby(str)      = fg256(197, str)

      # ── Semantic colors (trading-specific) ──────────────────────────
      #
      # Use these instead of raw green/red for PnL, risk, depth —
      # one place to swap for colorblind-friendly or light-mode themes.

      def profit(str)   = fg256(48, str)    # bright green-cyan
      def loss(str)     = fg256(196, str)   # vivid red
      def neutral(str)  = fg256(246, str)   # soft gray
      def muted(str)    = "\e[2m#{str}\e[0m"           # dim
      def accent(str)   = fg256(75, str)    # steel blue
      def warning(str)  = fg256(214, str)   # amber
      def critical(str) = "\e[48;5;196;38;5;231m#{str}\e[0m"  # white on red bg

      # UI Elements
      def ui_border(str) = fg256(238, str)  # dark gray border
      def ui_header(str) = bg256(237, fg256(254, " #{str} ")) # dark gray pill with light text

      # Depth-of-market / order book
      def bar_bid(str)  = fg256(29, str)    # deep green
      def bar_ask(str)  = fg256(124, str)   # deep red

      # ── Risk band colorizer ────────────────────────────────────────
      def color_risk_band(band)
        case band
        when 'CRIT' then on_red(" #{band} ")
        when 'HIGH' then ruby(band)
        when 'MED'  then gold(band)
        else emerald(band)
        end
      end

      # ── Regime colorizer ──────────────────────────────────────────
      def regime_color_label(r)
        label = (r.is_a?(Hash) ? r[:label] : r).to_s.upcase
        return tag_neutral(label) if label.empty? || label == '—'

        case label
        when 'BULL' then tag_live(label)
        when 'BEAR' then tag_critical(label)
        else tag_warning(label)
        end
      end

      # ── Layout helpers ─────────────────────────────────────────────
      def join_compact(_w, parts)
        parts.join(muted(' │ '))
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

      # ── Pill / Tag helpers ──────────────────────────────────────────
      def tag_live(str)     = "\e[48;5;28;38;5;231m #{str} \e[0m" # green pill
      def tag_warning(str)  = "\e[48;5;208;38;5;231m #{str} \e[0m" # orange pill
      def tag_critical(str) = "\e[48;5;160;38;5;231m #{str} \e[0m" # red pill
      def tag_neutral(str)  = "\e[48;5;239;38;5;231m #{str} \e[0m" # gray pill
      def tag_accent(str)   = "\e[48;5;33;38;5;231m #{str} \e[0m"  # blue pill

      # ── PnL / Numeric scaling ──────────────────────────────────────
      def color_pnl_pct(pct, label)
        return muted('—') if pct.nil?

        v = pct.to_f
        if v >= 2.0
          "\e[1;38;5;46m#{label}\e[0m"  # extreme green
        elsif v > 0
          profit(label)
        elsif v <= -5.0
          critical(label)               # extreme red
        elsif v < 0
          loss(label)
        else
          neutral(label)
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
