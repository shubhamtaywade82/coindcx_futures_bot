# frozen_string_literal: true

require 'tty-cursor'
require 'tty-screen'
require 'stringio'
require_relative '../term_width'
require_relative '../term_height'
require_relative '../theme'
require_relative '../ansi_string'
require_relative '../sparkline'

module CoindcxBot
  module Tui
    module Panels
      # Three-column futures desk: L2 book (focus pair) | execution + orders | risk + event log.
      class DeskFuturesGridPanel
        include Theme
        include AnsiString

        DEPTH_BLOCKS = %w[▏ ▎ ▍ ▌ ▋ ▊ ▉ █].freeze

        def initialize(engine:, tick_store:, order_book_store:, symbols:, focus_pair_proc:, origin_row:,
                       origin_col: 0, output: $stdout, flexible_height: nil)
          @engine = engine
          @tick_store = tick_store
          @order_book_store = order_book_store
          @symbols = Array(symbols).map(&:to_s)
          @focus_pair_proc = focus_pair_proc
          @row = origin_row
          @col = origin_col
          @output = output
          @cursor = TTY::Cursor
          @flexible_height = flexible_height
        end

        def render
          vm = DeskViewModel.build(
            engine: @engine,
            tick_store: @tick_store,
            symbols: @symbols,
            inner_height_override: @flexible_height
          )
          h = vm.inner_height
          snap = @engine.snapshot
          focus = @focus_pair_proc&.call&.to_s || @symbols.first.to_s
          w = term_width

          left_w, mid_w, right_w = column_widths(w)
          ew, ow = execution_order_widths(mid_w)
          wide_exec = ew >= 58

          exec_rows = pad_rows(vm.execution_rows, h)
          ord_rows = pad_rows(vm.order_flow_rows, h)
          book_rows = @order_book_store.display_rows(pair: focus, max_lines: h)
          sidebar = vm.grid_sidebar_lines
          sidebar_reserved = sidebar.size
          events = Array(snap.recent_events).last([h - sidebar_reserved, 0].max)

          buf = StringIO.new
          buf << @cursor.save
          r = @row

          buf << move(r) << ui_border(outer_top_rule(left_w, mid_w, right_w, focus))
          r += 1
          buf << move(r) << ui_border("│") << header_row(left_w, ew, ow, right_w, wide_exec: wide_exec) << ui_border("│")
          r += 1
          buf << move(r) << ui_border(mid_rule(left_w, mid_w, right_w))
          r += 1

          # Pre-compute max quantity for depth bars
          max_qty = compute_max_quantity(book_rows)

          h.times do |i|
            left = format_book_cell(book_rows[i], left_w, max_qty)
            ex = pad_visible(format_exec_cell(exec_rows[i], ew, wide_exec: wide_exec), ew)
            ord = pad_visible(format_ord_cell(ord_rows[i]), ow)
            mid = "#{ex}#{muted('│')}#{ord}"
            right = format_sidebar_row(sidebar, events, i, h, right_w, sidebar_reserved: sidebar_reserved)
            buf << move(r + i) << ui_border("│") << left << ui_border("│") << mid << ui_border("│") << right << ui_border("│")
          end

          r += h
          buf << move(r) << ui_border(outer_bot_rule(left_w, mid_w, right_w))
          buf << @cursor.restore

          @output.print buf.string
          @output.flush
        end

        def row_count
          vm = DeskViewModel.build(
            engine: @engine,
            tick_store: @tick_store,
            symbols: @symbols,
            inner_height_override: @flexible_height
          )
          4 + vm.inner_height
        end

        private

        def pad_rows(rows, h)
          out = rows.dup
          out << nil while out.size < h
          out.first(h)
        end

        # ── Depth heatmap bars ────────────────────────────────────────

        def compute_max_quantity(book_rows)
          max = 0.0
          book_rows.each do |row|
            next unless row.is_a?(Hash)

            q = row[:quantity].to_f
            max = q if q > max
          end
          max
        end

        def depth_bar(quantity, max_qty, bar_width)
          return ' ' * bar_width if max_qty <= 0

          ratio = quantity.to_f / max_qty
          # Each character position = 1/bar_width of full. Sub-character precision via block chars.
          full_units = (ratio * bar_width * 8).to_i
          full_blocks = full_units / 8
          remainder = full_units % 8

          bar = '█' * full_blocks
          bar += DEPTH_BLOCKS[remainder - 1] if remainder > 0 && bar.length < bar_width
          bar.ljust(bar_width)[0, bar_width]
        end

        # Split the BOOK column between price and quantity using the same rules as row rendering.
        def book_column_splits(left_col_w)
          # Give price and qty fixed reasonable widths to maximize the volume bar.
          avail = left_col_w - 6
          px_w = (avail * 0.35).to_i.clamp(8, 10)
          qty_w = (avail * 0.35).to_i.clamp(8, 12)
          [px_w, qty_w]
        end

        def format_book_cell(row, w, max_qty)
          line =
            case row
            when :empty
              muted('·')
            when Hash
              px_w, qty_w = book_column_splits(w)
              side = row[:side] == :ask ? loss('A') : profit('B')
              px = format_exec_qty(row[:price].to_s, px_w)
              q = format_exec_qty(row[:quantity].to_s, qty_w)
              bar_w = [w - px_w - qty_w - 5, 0].max
              bar_str =
                if bar_w >= 3
                  bar_raw = depth_bar(row[:quantity], max_qty, bar_w)
                  row[:side] == :ask ? bar_ask(bar_raw) : bar_bid(bar_raw)
                else
                  ''
                end
              " #{side} #{accent(px.ljust(px_w))} #{muted(q.rjust(qty_w))}#{bar_str.empty? ? '' : " #{bar_str}"} "
            else
              muted('·')
            end
          pad_visible(line, w)
        end

        # ── Execution (positions) ────────────────────────────────────

        def format_exec_cell(row, max_visible, wide_exec:)
          return muted('·') if row.nil?

          sym = compact_pair_symbol(row[:symbol])
          focus = @focus_pair_proc&.call&.to_s
          is_focus = row[:symbol].to_s == focus
          indicator = is_focus ? sapphire('»') : ' '
          spark_w = wide_exec ? 16 : 8
          spark = render_sparkline_for(row[:symbol], width: spark_w)

          if wide_exec
            line = format_exec_cell_wide(row, sym, spark, indicator)
            line = shrink_exec_line_to_fit(row, sym, spark, indicator) if visible_len(line) > max_visible
            line = format_exec_cell_compact(row, sym, spark, indicator) if visible_len(line) > max_visible
            line
          else
            format_exec_cell_compact(row, sym, spark, indicator)
          end
        end

        def render_sparkline_for(symbol, width: 8)
          hist = @tick_store.price_history(symbol.to_s, max: 20)
          return nil if hist.size < 3

          raw = Sparkline.render(hist, width: width)
          accent(raw)
        end

        def format_exec_cell_wide(row, sym, spark, indicator)
          lst = (row[:last] || row[:ltp]).to_s
          mrk = row[:mark].to_s
          side = row[:side].to_s.upcase
          side = side[0, 5].ljust(5) if side.length > 5
          side = side.ljust(5)
          parts = [
            "#{indicator}#{warning(truncate(sym, 6).ljust(6))}",
            muted(side),
            muted(format_exec_qty(row[:qty], 10).ljust(10)),
            muted(row[:entry].to_s.ljust(8)),
            accent(lst.ljust(8)),
            muted(mrk.ljust(8)),
            muted(row[:sl].to_s.ljust(7)),
            color_pnl_pct(extract_pct(row[:pnl_label]), row[:pnl_label])
          ]
          parts << muted("[#{row[:lane]}]") if row[:lane]
          parts << spark if spark
          parts.join(muted(' │ '))
        end

        def extract_pct(label)
          return nil unless label =~ /\(([-+]?[0-9.]+)\%\)/

          Regexp.last_match(1).to_f
        end

        def format_exec_cell_compact(row, sym, spark, indicator)
          mrk = row[:mark].to_s
          px = mrk.strip.empty? || mrk == '—' ? (row[:last] || row[:ltp]).to_s : mrk
          parts = [
            "#{indicator}#{warning(truncate(sym, 5).ljust(5))}",
            muted(side_abbrev(row[:side])),
            muted(format_exec_qty(row[:qty], 9).ljust(9)),
            muted(row[:entry].to_s.ljust(7)),
            muted(px.ljust(8)),
            color_pnl_pct(extract_pct(row[:pnl_label]), pnl_short_label(row))
          ]
          parts << spark if spark
          parts.join(muted(' │ '))
        end

        def shrink_exec_line_to_fit(row, sym, spark, indicator)
          lst = (row[:last] || row[:ltp]).to_s
          mrk = row[:mark].to_s
          side = row[:side].to_s.upcase
          side = side[0, 5].ljust(5)
          parts = [
            "#{indicator}#{warning(truncate(sym, 7).ljust(7))}",
            muted(side),
            muted(format_exec_qty(row[:qty], 12).ljust(12)),
            muted(row[:entry].to_s.ljust(9)),
            accent(lst.ljust(9)),
            muted(mrk.ljust(9)),
            muted(row[:sl].to_s.ljust(8)),
            color_pnl(row[:pnl_usdt], pnl_short_label(row))
          ]
          parts << spark if spark
          parts.join(muted(' │ '))
        end

        def pnl_short_label(row)
          u = row[:pnl_usdt]
          return '—' if u.nil?

          format('%+.2f', u.to_f)
        end

        def compact_pair_symbol(pair)
          pair.to_s.sub(/^B-/, '').sub(/_USDT\z/i, '')
        end

        def side_abbrev(side)
          s = side.to_s.downcase
          return '·' if s == 'flat'

          return 'L' if %w[long buy].include?(s)
          return 'S' if %w[short sell].include?(s)

          side.to_s[0] || '·'
        end

        def format_exec_qty(raw, max_chars)
          s = raw.to_s
          return '—' if s.strip.empty? || s == '—'
          return s if s.length <= max_chars

          f = Float(s)
          if f.abs >= 100_000
            t = format('%.2e', f)
          elsif f.abs >= 1000
            t = format('%.2f', f)
          else
            t = format('%.6g', f)
          end
          t = t[0, max_chars]
          t.length < s.length ? t : s[0, max_chars]
        rescue ArgumentError, TypeError
          truncate(s, max_chars)
        end

        # ── Orders ───────────────────────────────────────────────────

        def format_ord_cell(row)
          return muted('·') if row.nil?

          lat = row[:latency] ? accent("#{row[:latency]}ms") : muted('—')
          [
            warning(row[:type_abbr].to_s.ljust(3)),
            muted(truncate(row[:symbol].to_s, 9).ljust(9)),
            profit(row[:status].to_s[0, 3].ljust(3)),
            lat
          ].join(muted(' '))
        end

        # ── Sidebar (risk summary + events) ──────────────────────────

        def format_sidebar_row(sidebar, events, i, h, w, sidebar_reserved:)
          text =
            if i < sidebar_reserved
              sidebar[i] || muted('·')
            else
              ev_i = i - sidebar_reserved
              if ev_i < events.size
                format_event(events[ev_i], w)
              else
                muted('·')
              end
            end
          pad_visible(text, w)
        end

        def format_event(ev, w)
          ts = ev[:ts].to_i
          t = Time.at(ts).strftime('%H:%M:%S')
          type = ev[:type].to_s.upcase
          hint = payload_hint(ev[:payload])
          raw = "#{t} #{bold(type.ljust(9))} #{hint}".strip
          raw.length > w ? "#{raw[0, w - 1]}…" : raw
        end

        def payload_hint(pl)
          return '' unless pl.is_a?(Hash)

          pair = pl[:pair] || pl['pair']
          bits = [pair].compact.map(&:to_s)
          oc = pl[:outcome] || pl['outcome']
          bits << oc.to_s if oc.to_s.strip != ''
          bits.join(' ')
        end

        # ── Layout ───────────────────────────────────────────────────

        def term_width
          TermWidth.columns
        end

        def column_widths(total_w)
          left = (total_w * 0.28).to_i
          left = 32 if left < 32
          left = 52 if left > 52
          right = (total_w * 0.30).to_i.clamp(25, 60)
          mid = total_w - left - right - 2
          [left, mid, right]
        end

        def execution_order_widths(mid_w)
          inner = [mid_w - 1, 18].max
          ow = (inner * 0.28).to_i.clamp(18, 26)
          ew = inner - ow
          if ew < 34
            ow = [inner - 34, 16].max
            ew = inner - ow
          end
          [ew, ow]
        end

        def outer_top_rule(lw, mw, rw, focus)
          fp = truncate(focus.to_s, 14)
          title = ui_header(" BOOK · #{fp} ")
          rem_l = lw - visible_len(title)
          l1 = (rem_l / 2).clamp(1, lw)
          l2 = (rem_l - l1).clamp(1, lw)

          t2 = ui_header(' POSITIONS · ORDERS ')
          rem_m = mw - visible_len(t2)
          m1 = (rem_m / 2).clamp(1, mw)
          m2 = (rem_m - m1).clamp(1, mw)

          t3 = ui_header(' RISK · LOG ')
          rem_r = rw - visible_len(t3)
          r1 = (rem_r / 2).clamp(1, rw)
          r2 = (rem_r - r1).clamp(1, rw)

          "┌#{'─' * l1}#{title}#{'─' * l2}┬#{'─' * m1}#{t2}#{'─' * m2}┬#{'─' * r1}#{t3}#{'─' * r2}┐"
        end

        def outer_bot_rule(lw, mw, rw)
          "└#{'─' * lw}┴#{'─' * mw}┴#{'─' * rw}┘"
        end

        def mid_rule(lw, mw, rw)
          ui_border("├#{'─' * lw}┼#{'─' * mw}┼#{'─' * rw}┤")
        end

        def header_row(lw, ew, ow, rw, wide_exec:)
          px_w, qty_w = book_column_splits(lw)
          bar_w = [lw - px_w - qty_w - 5, 0].max
          bar_hdr = bar_w >= 3 ? muted('VOL'.ljust(bar_w)) : ''
          lh = [" #{muted('S')}", muted('PRICE'.ljust(px_w)), muted('QTY'.rjust(qty_w))]
          lh << bar_hdr unless bar_hdr.empty?
          lh_str = lh.join(muted(' '))
          eh =
            if wide_exec
              [
                " #{muted('SYM'.ljust(6))}",
                muted('SIDE'.ljust(5)),
                muted('QTY'.ljust(10)),
                muted('ENT'.ljust(8)),
                muted('LAST'.ljust(8)),
                muted('MARK'.ljust(8)),
                muted('SL'.ljust(7)),
                muted('PNL')
              ].join(muted(' '))
            else
              [
                " #{muted('SYM'.ljust(5))}",
                muted('S'),
                muted('QTY'.ljust(9)),
                muted('ENT'.ljust(7)),
                muted('MARK'.ljust(8)),
                muted('PNL')
              ].join(muted(' '))
            end
          oh = [
            " #{muted('T'.ljust(3))}",
            muted('PAIR'.ljust(9)),
            muted('ST'.ljust(3)),
            muted('LAT')
          ].join(muted(' '))
          rh = " #{muted('SUMMARY · EVENTS')}"
          "#{pad_visible(lh_str, lw)}#{muted('│')}#{pad_visible(eh, ew)}#{muted('│')}#{pad_visible(oh, ow)}#{muted('│')}#{pad_visible(rh, rw)}"
        end

        def pad_plain(text, w)
          t = text.length > w ? "#{text[0, [w - 1, 0].max]}…" : text
          t.ljust(w)
        end

        def move(row)
          @cursor.move_to(@col, row)
        end

        def clr(content)
          "#{content}\e[K"
        end
      end
    end
  end
end
