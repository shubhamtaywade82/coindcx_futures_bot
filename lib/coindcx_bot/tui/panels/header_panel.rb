# frozen_string_literal: true

require 'bigdecimal'
require 'tty-cursor'
require 'tty-screen'
require 'stringio'
require_relative '../term_width'
require_relative '../theme'
require_relative '../ansi_string'

module CoindcxBot
  module Tui
    module Panels
      # Top status strip: execution-first summary (mode, engine, kill, feed, then FOCUS/LEV, latency last).
      class HeaderPanel
        include Theme
        include AnsiString

        def initialize(engine:, origin_row: 0, origin_col: 0, output: $stdout, focus_pair_proc: nil)
          @engine = engine
          @focus_pair_proc = focus_pair_proc
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
          buf << move(@row)     << clr(line_mode_engine_kill_ws_lat_feed(snap, w))
          buf << move(@row + 1) << clr(line_balance_net_real_unreal_dd_risk(snap, vm, w))
          buf << move(@row + 2) << clr(line_pos_ord_err_last(snap, vm, w))
          buf << move(@row + 3) << clr(muted('─' * [[w - 1, 40].max, 120].min))
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
          TermWidth.columns
        end

        def move(row)
          @cursor.move_to(@col, row)
        end

        def line_mode_engine_kill_ws_lat_feed(snap, w)
          mode = snap.dry_run ? bold_magenta('PAPER') : bold_red('LIVE')
          profile = trading_profile_fragment
          eng =
            if @engine.engine_loop_crashed?
              on_red(' ENGINE: CRASHED ')
            elsif snap.running
              profit('ENGINE: RUN')
            else
              loss('ENGINE: STOP')
            end
          pause = snap.paused ? on_yellow(' PAUSED ') : nil
          kill = snap.kill_switch ? on_red(' KILL: ON ') : muted('KILL: OFF')
          ws =
            if snap.stale
              loss('WS: ○')
            else
              profit('WS: ●')
            end
          lat =
            if snap.ws_last_tick_ms_ago
              muted('LAT: ') + accent("#{snap.ws_last_tick_ms_ago}ms")
            else
              muted('LAT: —')
            end
          feed = snap.stale ? on_yellow(' FEED: STALE ') : profit('FEED: OK')
          join_compact(
            w,
            [
              "MODE: #{mode}", profile, regime_header_fragment(snap), eng, pause,
              kill, ws, feed, focus_fragment, leverage_fragment, lat
            ].compact
          )
        end

        def line_balance_net_real_unreal_dd_risk(snap, vm, w)
          bal = balance_line(snap)
          net = bold('NET: ') + colored_inr(snap.daily_pnl)
          rest =
            if paper_metrics?(snap)
              pm = snap.paper_metrics
              funding_s = pm[:total_funding_fees] ? "#{bold('FUND: ')}#{fmt_num(pm[:total_funding_fees])}" : nil
              parts = [
                "#{bold('REAL USDT: ')}#{fmt_num(pm[:total_realized_pnl])}",
                "#{bold('UNREAL USDT: ')}#{colored_num(pm[:unrealized_pnl])}",
                funding_s,
                "#{bold('DD: ')}#{fmt_dd(vm.drawdown_pct)}",
                "#{bold('RISK: ')}#{color_risk_band(vm.risk_band)}"
              ].compact.join(muted(' │ '))
            else
              [
                muted('REAL USDT: —'),
                muted('UNREAL USDT: —'),
                "#{bold('DD: ')}#{fmt_dd(vm.drawdown_pct)}",
                "#{bold('RISK: ')}#{color_risk_band(vm.risk_band)}"
              ].join(muted(' │ '))
            end
          join_compact(w, [bal, net, rest])
        end

        # Paper: config capital (INR) + (realized + unrealized) USDT × inr_per_usdt (mark-to-market equity).
        # Live: config capital only.
        def balance_line(snap)
          if paper_metrics?(snap)
            base = snap.capital_inr || BigDecimal('0')
            realized_usdt = BigDecimal((snap.paper_metrics[:total_realized_pnl] || 0).to_s)
            unreal_usdt = BigDecimal((snap.paper_metrics[:unrealized_pnl] || 0).to_s)
            fx = @engine.inr_per_usdt
            total = base + ((realized_usdt + unreal_usdt) * fx)
            bold('BAL: ') + fmt_inr(total)
          elsif snap.capital_inr
            bold('BAL: ') + fmt_inr(snap.capital_inr)
          else
            muted('BAL: —')
          end
        rescue ArgumentError, TypeError
          muted('BAL: —')
        end

        def line_pos_ord_err_last(snap, vm, w)
          pos_n = Array(snap.positions).size
          ord_n = Array(snap.working_orders).size
          err = snap.last_error ? loss('1') : muted('0')
          last = accent(vm.last_event_type.to_s)
          join_compact(
            w,
            [
              "#{bold('POS: ')}#{pos_n}",
              "#{bold('ORD: ')}#{ord_n}",
              "#{bold('ERR: ')}#{err}",
              "#{bold('LAST EVT: ')}#{last}"
            ]
          )
        end

        def fmt_dd(pct)
          return muted('—') if pct.nil?

          v = pct.to_f
          s = format('%+.2f%%', v)
          v.negative? ? loss(s) : muted(s)
        end

        def colored_inr(v)
          bd = BigDecimal(v.to_s)
          s = fmt_inr(bd)
          return profit(s) if bd.positive?
          return loss(s) if bd.negative?

          neutral(s)
        rescue ArgumentError, TypeError
          muted('₹0.00')
        end

        def colored_num(v)
          bd = BigDecimal((v || 0).to_s)
          s = fmt_num(bd)
          return profit(s) if bd.positive?
          return loss(s) if bd.negative?

          warning(s)
        rescue ArgumentError, TypeError
          muted('0.00')
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

        def trading_profile_fragment
          cfg = @engine.config
          return nil unless cfg.respond_to?(:scalper_mode?) && cfg.scalper_mode?

          warning('SCALP')
        end

        def regime_header_fragment(snap)
          r = snap.regime
          return nil unless r.is_a?(Hash) && r[:enabled]

          return profit('REGIME·LIVE') if r[:active]

          accent('REGIME·ON')
        end

        def focus_fragment
          p = @focus_pair_proc&.call
          return nil if p.nil? || p.to_s.strip.empty?

          muted('FOCUS: ') + accent(compact_instrument_label(p))
        end

        def leverage_fragment
          od = @engine.config.execution[:order_defaults] || {}
          lev = od[:leverage] || od['leverage']
          cap = @engine.config.risk[:max_leverage]
          a = optional_positive_int(lev)
          b = optional_positive_int(cap)
          return nil if a.nil? && b.nil?

          v = [a, b].compact.min
          return nil if v.nil? || v <= 0

          muted('LEV: ') + warning("#{v}x")
        end

        def optional_positive_int(raw)
          return nil if raw.nil? || raw.to_s.strip.empty?

          Integer(raw)
        rescue ArgumentError, TypeError
          nil
        end

        def compact_instrument_label(pair)
          pair.to_s.sub(/\AB-/, '').sub(/_USDT\z/i, '')
        end

        def join_compact(_w, parts)
          parts.join(muted(' │ '))
        end

        def clr(content)
          "#{content}\e[K"
        end
      end
    end
  end
end
