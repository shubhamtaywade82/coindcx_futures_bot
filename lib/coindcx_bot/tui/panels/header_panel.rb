# frozen_string_literal: true

require 'bigdecimal'
require 'tty-cursor'
require 'tty-screen'
require 'stringio'

module CoindcxBot
  module Tui
    module Panels
      # Top status strip: execution-first summary (mode, engine, kill, feed, latency, balances, desk counts).
      class HeaderPanel
        def initialize(engine:, origin_row: 0, origin_col: 0, output: $stdout)
          @engine = engine
          @row = origin_row
          @col = origin_col
          @output = output
          @cursor = TTY::Cursor
        end

        def render
          snap = @engine.snapshot
          vm = desk_vm(snap)
          w = term_width

          buf = StringIO.new
          buf << @cursor.save
          buf << move(@row)     << clear_line(line_mode_engine_kill_ws_lat_feed(snap, w))
          buf << move(@row + 1) << clear_line(line_balance_net_real_unreal_dd_risk(snap, vm, w))
          buf << move(@row + 2) << clear_line(line_pos_ord_err_last(snap, vm, w))
          buf << move(@row + 3) << clear_line(dim('─' * [[w - 1, 40].max, 120].min))
          buf << @cursor.restore

          @output.print buf.string
          @output.flush
        end

        def row_count
          4
        end

        private

        def desk_vm(snap)
          DeskViewModel.new(
            snapshot: snap,
            tick_ticks: {},
            symbols: Array(snap.pairs),
            ws_stale_fn: ->(sym) { @engine.ws_feed_stale?(sym) },
            config: @engine.config
          )
        end

        def term_width
          TTY::Screen.width || 80
        end

        def move(row)
          @cursor.move_to(@col, row)
        end

        def line_mode_engine_kill_ws_lat_feed(snap, w)
          mode = snap.dry_run ? bold_magenta('PAPER') : bold_red('LIVE')
          eng =
            if snap.running
              green('ENGINE: RUN')
            else
              red('ENGINE: STOP')
            end
          pause = snap.paused ? on_yellow(' PAUSED ') : nil
          kill = snap.kill_switch ? on_red(' KILL: ON ') : dim('KILL: OFF')
          ws =
            if snap.stale
              red('WS: ○')
            else
              green('WS: ●')
            end
          lat =
            if snap.ws_last_tick_ms_ago
              dim('LAT: ') + cyan("#{snap.ws_last_tick_ms_ago}ms")
            else
              dim('LAT: —')
            end
          feed = snap.stale ? on_yellow(' FEED: STALE ') : green('FEED: OK')
          join_compact(w, ["MODE: #{mode}", eng, pause, kill, ws, lat, feed].compact)
        end

        def line_balance_net_real_unreal_dd_risk(snap, vm, w)
          bal = balance_line(snap)
          net = bold('NET: ') + colored_inr(snap.daily_pnl)
          rest =
            if paper_metrics?(snap)
              pm = snap.paper_metrics
              [
                "#{bold('REAL USDT: ')}#{fmt_num(pm[:total_realized_pnl])}",
                "#{bold('UNREAL USDT: ')}#{colored_num(pm[:unrealized_pnl])}",
                "#{bold('DD: ')}#{fmt_dd(vm.drawdown_pct)}",
                "#{bold('RISK: ')}#{color_risk_band(vm.risk_band)}"
              ].join(dim(' │ '))
            else
              [
                dim('REAL USDT: —'),
                dim('UNREAL USDT: —'),
                "#{bold('DD: ')}#{fmt_dd(vm.drawdown_pct)}",
                "#{bold('RISK: ')}#{color_risk_band(vm.risk_band)}"
              ].join(dim(' │ '))
            end
          join_compact(w, [bal, net, rest])
        end

        # Paper: config capital (INR) + cumulative realized USDT × inr_per_usdt. Live: config capital only.
        def balance_line(snap)
          if paper_metrics?(snap)
            base = snap.capital_inr || BigDecimal('0')
            realized_usdt = BigDecimal((snap.paper_metrics[:total_realized_pnl] || 0).to_s)
            fx = @engine.config.inr_per_usdt
            total = base + (realized_usdt * fx)
            bold('BAL: ') + fmt_inr(total)
          elsif snap.capital_inr
            bold('BAL: ') + fmt_inr(snap.capital_inr)
          else
            dim('BAL: —')
          end
        rescue ArgumentError, TypeError
          dim('BAL: —')
        end

        def line_pos_ord_err_last(snap, vm, w)
          pos_n = Array(snap.positions).size
          ord_n = Array(snap.working_orders).size
          err = snap.last_error ? red('1') : dim('0')
          last = cyan(vm.last_event_type.to_s)
          join_compact(
            w,
            [
              "#{bold('POS: ')}#{pos_n}",
              "#{bold('ORD: ')}#{ord_n}",
              "#{bold('ERR: ')}#{err}",
              "#{bold('LAST: ')}#{last}"
            ]
          )
        end

        def fmt_dd(pct)
          return dim('—') if pct.nil?

          v = pct.to_f
          s = format('%+.2f%%', v)
          v.negative? ? red(s) : dim(s)
        end

        def color_risk_band(band)
          case band
          when 'CRIT' then on_red(" #{band} ")
          when 'HIGH' then red(band)
          when 'MED' then yellow(band)
          else green(band)
          end
        end

        def colored_inr(v)
          bd = BigDecimal(v.to_s)
          s = fmt_inr(bd)
          return green(s) if bd.positive?
          return red(s) if bd.negative?

          dim(s)
        rescue ArgumentError, TypeError
          dim('₹0.00')
        end

        def colored_num(v)
          bd = BigDecimal((v || 0).to_s)
          s = fmt_num(bd)
          return green(s) if bd.positive?
          return red(s) if bd.negative?

          yellow(s)
        rescue ArgumentError, TypeError
          dim('0.00')
        end

        def paper_metrics?(snap)
          snap.paper_metrics.is_a?(Hash) && snap.paper_metrics.any?
        end

        def fmt_inr(v)
          format('₹%.2f', BigDecimal(v.to_s))
        rescue ArgumentError, TypeError
          '₹0.00'
        end

        def fmt_num(v)
          format('%.2f', BigDecimal((v || 0).to_s))
        rescue ArgumentError, TypeError
          '0.00'
        end

        def join_compact(_w, parts)
          parts.join(dim(' │ '))
        end

        def clear_line(content)
          "#{content}\e[K"
        end

        def bold(str)           = "\e[1m#{str}\e[0m"
        def bold_magenta(str)   = "\e[1;35m#{str}\e[0m"
        def bold_red(str)       = "\e[1;31m#{str}\e[0m"
        def cyan(str)           = "\e[36m#{str}\e[0m"
        def green(str)          = "\e[32m#{str}\e[0m"
        def yellow(str)         = "\e[33m#{str}\e[0m"
        def red(str)            = "\e[31m#{str}\e[0m"
        def dim(str)            = "\e[2m#{str}\e[0m"
        def on_yellow(str)      = "\e[43;30m#{str}\e[0m"
        def on_red(str)         = "\e[41;37m#{str}\e[0m"
      end
    end
  end
end
