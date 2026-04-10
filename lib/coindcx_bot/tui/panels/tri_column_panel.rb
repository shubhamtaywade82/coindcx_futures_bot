# frozen_string_literal: true

require 'bigdecimal'
require 'tty-cursor'
require 'tty-screen'
require 'stringio'

module CoindcxBot
  module Tui
    module Panels
      # Three columns: engine tickers (tracker LTP) | journal positions | working orders (paper).
      class TriColumnPanel
        def initialize(engine:, symbols:, origin_row:, origin_col: 0, output: $stdout, max_inner_height: 10)
          @engine = engine
          @symbols = Array(symbols).map(&:to_s)
          @row = origin_row
          @col = origin_col
          @output = output
          @cursor = TTY::Cursor
          @max_inner = max_inner_height.to_i.positive? ? max_inner_height.to_i : 10
        end

        def render
          snap = @engine.snapshot
          w = term_width
          inner_w = column_width(w)
          inner_h = inner_height_for(snap)

          left = build_ticker_lines(snap)
          mid = build_positions_lines(snap)
          right = build_orders_lines(snap)

          left  = pad_column(left, inner_h, inner_w)
          mid   = pad_column(mid, inner_h, inner_w)
          right = pad_column(right, inner_h, inner_w)

          buf = StringIO.new
          buf << @cursor.save
          r = @row
          buf << move(r) << clear_line(top_rule(inner_w))
          r += 1
          buf << move(r) << clear_line(title_row(inner_w))
          r += 1
          buf << move(r) << clear_line(mid_rule(inner_w))
          r += 1
          inner_h.times do |i|
            buf << move(r + i) << clear_line(data_row(left[i], mid[i], right[i], inner_w))
          end
          r += inner_h
          buf << move(r) << clear_line(bot_rule(inner_w))
          buf << @cursor.restore

          @output.print buf.string
          @output.flush
        end

        def row_count
          4 + inner_height_for(@engine.snapshot)
        end

        private

        def inner_height_for(snap)
          left = build_ticker_lines(snap)
          mid = build_positions_lines(snap)
          right = build_orders_lines(snap)
          inner_h = [left.size, mid.size, right.size, 1].max
          [inner_h, @max_inner].min
        end

        def term_width
          w = TTY::Screen.width
          w = w.to_i if w
          w = 80 if w.nil? || w < 40
          w
        end

        def column_width(total_w)
          inner = total_w - 4
          w = (inner / 3) - 1
          [w, 18].max
        end

        def move(row)
          @cursor.move_to(@col, row)
        end

        def pad_column(lines, h, inner_w)
          arr = lines.dup
          arr << dim('·') while arr.size < h
          arr[0, h].map { |ln| truncate_pad(ln.to_s, inner_w) }
        end

        def truncate_pad(str, w)
          return str.ljust(w) if visible_len(str) <= w

          "#{slice_visible(str, w - 1)}…".ljust(w + (str.length - visible_len(str)))
        end

        def visible_len(s)
          s.gsub(/\e\[[0-9;]*m/, '').length
        end

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

        def build_ticker_lines(snap)
          @symbols.map do |sym|
            t = snap.ticks[sym]
            price = t && t[:price] ? format('%.2f', BigDecimal(t[:price].to_s)) : '—'
            sym_l = sym.length > 12 ? "#{sym[0, 11]}…" : sym
            "#{dim(sym_l)}  #{green(price)}"
          end
        end

        def build_positions_lines(snap)
          lines = []
          pos = Array(snap.positions)
          if pos.empty?
            lines << dim('(none)')
            return lines
          end

          pos.first(2).each { |p| lines.concat(position_block_lines(p, snap)) }
          lines << dim("(+#{pos.size - 2})") if pos.size > 2
          lines
        end

        def position_block_lines(p, snap)
          pair = (p[:pair] || p['pair']).to_s
          side = (p[:side] || p['side']).to_s
          entry = p[:entry_price] || p['entry_price']
          t = snap.ticks[pair]
          ltp = t && t[:price]
          sp = p[:stop_price] || p['stop_price']
          tr = p[:trail_price] || p['trail_price']

          u = unrealized_usdt(p, ltp)
          pct = unrealized_pct(p, ltp)
          pnl_s =
            if u
              c = u.positive? ? green(fmt_bd(u)) : u.negative? ? red(fmt_bd(u)) : yellow(fmt_bd(u))
              "#{c} (#{pct})"
            else
              dim('—')
            end

          ltp_s = ltp ? format('%.2f', BigDecimal(ltp.to_s)) : '—'
          sltp = []
          sltp << "SL:#{fmt_opt(sp)}" if sp && !sp.to_s.strip.empty?
          sltp << "TR:#{fmt_opt(tr)}" if tr && !tr.to_s.strip.empty?
          exit_s = sltp.any? ? sltp.join(dim(' │ ')) : dim('SL: —')

          [
            "#{yellow(pair)} #{dim(side)}",
            "#{dim('ENTRY')} #{fmt_opt(entry)}",
            "#{dim('LTP')} #{ltp_s} #{dim('u')} #{pnl_s}",
            exit_s
          ]
        end

        def fmt_opt(v)
          return '—' if v.nil? || v.to_s.strip.empty?

          format('%.2f', BigDecimal(v.to_s))
        rescue ArgumentError, TypeError
          '—'
        end

        def fmt_bd(v)
          format('%.2f', v)
        end

        def unrealized_usdt(p, ltp)
          return nil if ltp.nil?

          q = BigDecimal((p[:quantity] || p['quantity']).to_s)
          e = BigDecimal((p[:entry_price] || p['entry_price']).to_s)
          l = BigDecimal(ltp.to_s)
          case (p[:side] || p['side']).to_s
          when 'long', 'buy'
            (l - e) * q
          when 'short', 'sell'
            (e - l) * q
          else
            BigDecimal('0')
          end
        rescue ArgumentError, TypeError
          nil
        end

        def unrealized_pct(p, ltp)
          return '—' if ltp.nil?

          e = BigDecimal((p[:entry_price] || p['entry_price']).to_s)
          l = BigDecimal(ltp.to_s)
          return '0%' if e.zero?

          pct =
            case (p[:side] || p['side']).to_s
            when 'long', 'buy'
              ((l - e) / e) * 100
            when 'short', 'sell'
              ((e - l) / e) * 100
            else
              BigDecimal('0')
            end
          format('%+.2f%%', pct)
        rescue ArgumentError, TypeError
          '—'
        end

        def build_orders_lines(snap)
          wo = Array(snap.working_orders)
          return [dim('(none)')] if wo.empty?

          wo.first(@max_inner).map do |o|
            pair = o[:pair].to_s
            side = o[:side].to_s
            ot = o[:order_type].to_s
            "#{green(side.upcase)} #{dim(pair)} #{dim(ot)} #{yellow('PENDING')}"
          end
        end

        def top_rule(inner_w)
          "┌#{'─' * inner_w}┬#{'─' * inner_w}┬#{'─' * inner_w}┐"
        end

        def mid_rule(inner_w)
          "├#{'─' * inner_w}┼#{'─' * inner_w}┼#{'─' * inner_w}┤"
        end

        def bot_rule(inner_w)
          "└#{'─' * inner_w}┴#{'─' * inner_w}┴#{'─' * inner_w}┘"
        end

        def title_row(inner_w)
          t = 'TICKERS'.ljust(inner_w)
          p = 'POSITIONS'.ljust(inner_w)
          o = 'ORDERS'.ljust(inner_w)
          "│#{bold(t)}│#{bold(p)}│#{bold(o)}│"
        end

        def data_row(left, mid, right, inner_w)
          "│#{left}│#{mid}│#{right}│"
        end

        def clear_line(content)
          "#{content}\e[K"
        end

        def bold(str)   = "\e[1m#{str}\e[0m"
        def green(str)  = "\e[32m#{str}\e[0m"
        def yellow(str) = "\e[33m#{str}\e[0m"
        def red(str)    = "\e[31m#{str}\e[0m"
        def dim(str)    = "\e[2m#{str}\e[0m"
      end
    end
  end
end
