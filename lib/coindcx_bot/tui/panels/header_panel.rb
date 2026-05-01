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
        strip = show_live_futures_account_strip?(snap)

        buf = StringIO.new
        buf << @cursor.save
        r = @row

        # Top border with title
        title = ui_header(" SYSTEM STATUS ")
        rem = w - 2 - visible_len(title)
        l1 = (rem / 2).clamp(1, w)
        l2 = (rem - l1).clamp(1, w)
        buf << move(r) << ui_border("┌#{'─' * l1}#{title}#{'─' * l2}┐")
        r += 1

        # System row
        buf << move(r) << ui_border("│ ") << pad_visible(line_mode_engine_kill_ws_lat_feed(snap, w - 4), w - 4) << ui_border(" │")
        r += 1

        # Set engine focus for regime AI strip overlay context
        @engine.tui_focus_pair = @focus_pair_proc&.call

        # Account row (Reserving space for stability)
        if strip
          buf << move(r) << ui_border("│ ") << pad_visible(line_live_equity_wallet_unreal(snap, w - 4), w - 4) << ui_border(" │")
        else
          buf << move(r) << ui_border("│ ") << pad_visible(muted(" (AWAITING ACCOUNT METRICS) "), w - 4) << ui_border(" │")
        end
        r += 1

        # Balance & Risk row
        buf << move(r) << ui_border("│ ") << pad_visible(line_balance_net_real_unreal_dd_risk(snap, vm, w - 4), w - 4) << ui_border(" │")
        r += 1

        # Stats row
        buf << move(r) << ui_border("│ ") << pad_visible(line_pos_ord_err_last(snap, vm, w - 4), w - 4) << ui_border(" │")
        r += 1

        # Bottom border
        buf << move(r) << ui_border("└#{'─' * (w - 2)}┘")
        buf << @cursor.restore

        @output.print buf.string
        @output.flush
      end

      def row_count
        6
      end

        private

        def desk_vm(snap)
          DeskViewModel.new(
            snapshot: snap,
            tick_ticks: {},
            symbols: Array(snap.pairs),
            ws_stale_fn: ->(sym) { @engine.ws_feed_stale?(sym) },
            config: @engine.config,
            inr_per_usdt: @engine.inr_per_usdt
          )
        end

        def term_width
          TermWidth.columns
        end

        def move(row)
          @cursor.move_to(@col, row)
        end

        def line_mode_engine_kill_ws_lat_feed(snap, w)
          m = snap.dry_run ? 'PAPER' : 'LIVE'
          m_clr =
            if m == 'LIVE'
              tag_live(m)
            elsif m == 'PAUSED'
              tag_warning(m)
            else
              tag_neutral(m)
            end

          exe_clr = truthy?(snap.live_tui_metrics[:order_placement_enabled]) ? tag_accent('EXE·ON') : tag_neutral('EXE·OFF')
          reg_clr = regime_color_label(snap.regime)
          eng_clr = snap.running ? tag_live('RUNNING') : tag_critical('CRASHED')
          kill_clr = snap.kill_switch ? tag_critical('KILL: ON') : muted('KILL: OFF')
          ws_clr = ws_status_pill(snap.ws_last_tick_ms_ago)
          feed_clr = snap.stale ? tag_critical('FEED: STALE') : tag_live('FEED: OK')
          focus_clr = bold_cyan(snap.pairs.first.to_s.sub(/^B-/, ''))

          parts = [
            m_clr, exe_clr, reg_clr, eng_clr, kill_clr, ws_clr, feed_clr,
            "#{muted('FOCUS:')} #{focus_clr}",
            "#{muted('LEV:')} #{gold(snap.live_tui_metrics[:leverage_label] || '—')}"
          ]
          parts.join('  ')
        end

        def ws_status_pill(ms)
          return tag_critical('WS: DOWN') if ms.nil? || ms > 5000
          return tag_warning('WS: SLOW') if ms > 2000

          tag_live('WS: OK')
        end

        def line_balance_net_real_unreal_dd_risk(snap, vm, w)
          bal = balance_line(snap)
          net_inr = net_pnl_inr_for_header(snap, vm)
          net = bold('NET: ') + colored_inr(net_inr)
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
            elsif live_tui_metrics?(snap)
              m = snap.live_tui_metrics
              real = m[:realized_usdt] || BigDecimal('0')
              unreal = m[:unrealized_usdt] || BigDecimal('0')
              [
                "#{bold('REAL USDT: ')}#{fmt_num(real)}",
                "#{bold('UNREAL USDT: ')}#{colored_num(unreal)}",
                "#{bold('DD: ')}#{fmt_dd(vm.drawdown_pct)}",
                "#{bold('RISK: ')}#{color_risk_band(vm.risk_band)}"
              ].join(muted(' │ '))
            else
              [
                muted('REAL USDT: —'),
                muted('UNREAL USDT: —'),
                "#{bold('DD: ')}#{fmt_dd(vm.drawdown_pct)}",
                "#{bold('RISK: ')}#{color_risk_band(vm.risk_band)}"
              ].join(muted(' │ '))
            end
          join_compact(w, [bal, net, rest].compact)
        end

        # Desk-wide daily PnL: live mirror uses **exchange REAL+UNREAL (USDT) × FX** (+DeskViewModel#daily_pnl_inr_for_desk+).
        def net_pnl_inr_for_header(_snap, vm)
          vm.daily_pnl_inr_for_desk
        end

        # Paper: config capital (INR) + (realized + unrealized) USDT × inr_per_usdt (mark-to-market equity).
        # Live: config capital only; with +live_tui_metrics+ (exchange mirror): futures wallet in margin currency
        # (INR shown as-is; USDT converted via +inr_per_usdt+).
        def balance_line(snap)
          return nil if show_live_futures_account_strip?(snap)

          if paper_metrics?(snap)
            base = snap.capital_inr || BigDecimal('0')
            realized_usdt = BigDecimal((snap.paper_metrics[:total_realized_pnl] || 0).to_s)
            unreal_usdt = BigDecimal((snap.paper_metrics[:unrealized_pnl] || 0).to_s)
            fx = @engine.inr_per_usdt
            total = base + ((realized_usdt + unreal_usdt) * fx)
            bold('BAL: ') + fmt_inr(total)
          elsif live_tui_metrics?(snap)
            m = snap.live_tui_metrics
            fx = @engine.inr_per_usdt
            if m[:wallet_amount] && m[:wallet_currency]
              amt = BigDecimal(m[:wallet_amount].to_s)
              case m[:wallet_currency].to_s.upcase
              when 'INR'
                bold('BAL: ') + fmt_inr(amt) + muted(' ·futures wallet')
              when 'USDT'
                bold('BAL: ') + fmt_inr(amt * fx) + muted(' ·futures wallet')
              else
                muted('BAL: —')
              end
            elsif m[:balance_usdt]
              wallet_inr = BigDecimal(m[:balance_usdt].to_s) * fx
              bold('BAL: ') + fmt_inr(wallet_inr) + muted(' ·futures wallet')
            elsif snap.capital_inr
              unreal = BigDecimal((m[:unrealized_usdt] || 0).to_s)
              base = snap.capital_inr
              bold('BAL: ') + fmt_inr(base + (unreal * fx)) + muted(' ·cap+unreal')
            else
              muted('BAL: —')
            end
          elsif snap.capital_inr
            bold('BAL: ') + fmt_inr(snap.capital_inr)
          else
            muted('BAL: —')
          end
        rescue ArgumentError, TypeError
          muted('BAL: —')
        end

        def line_pos_ord_err_last(snap, vm, w)
          pos_n = vm.display_open_positions_count
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

        def live_tui_metrics?(snap)
          m = snap.live_tui_metrics
          return false unless m.is_a?(Hash) && m.any?

          m.key?(:wallet_amount) ||
            m.key?(:wallet_available) ||
            m.key?(:wallet_locked) ||
            m.key?(:wallet_cross_order_margin) ||
            m.key?(:wallet_cross_user_margin) ||
            m.key?(:balance_usdt) ||
            m.key?(:realized_usdt) ||
            m.key?(:unrealized_usdt) ||
            m.key?(:open_positions_count)
        end

        # Live futures mirror: wallet balance (API) + summed uPnL → equity; each shown in INR and USDT.
        def show_live_futures_account_strip?(snap)
          return false if snap.dry_run
          return false unless live_tui_metrics?(snap)

          dual_futures_account_metrics(snap).is_a?(Hash)
        end

        def dual_futures_account_metrics(snap)
          fx = safe_inr_per_usdt_bigdecimal
          return nil if fx.nil? || !fx.positive?

          m = snap.live_tui_metrics
          ur = BigDecimal((m[:unrealized_usdt] || 0).to_s)

          wal_inr, wal_usdt =
            if m[:wallet_amount] && m[:wallet_currency]
              amt = BigDecimal(m[:wallet_amount].to_s)
              case m[:wallet_currency].to_s.upcase
              when 'INR'
                [amt, amt / fx]
              when 'USDT'
                [amt * fx, amt]
              else
                return nil
              end
            elsif m[:balance_usdt]
              usdt = BigDecimal(m[:balance_usdt].to_s)
              [usdt * fx, usdt]
            else
              return nil
            end

          ur_usdt = ur
          ur_inr = ur * fx
          {
            eq_inr: wal_inr + ur_inr,
            eq_usdt: wal_usdt + ur_usdt,
            wal_inr: wal_inr,
            wal_usdt: wal_usdt,
            ur_inr: ur_inr,
            ur_usdt: ur_usdt
          }
        rescue ArgumentError, TypeError
          nil
        end

        def safe_inr_per_usdt_bigdecimal
          BigDecimal(@engine.inr_per_usdt.to_s)
        rescue ArgumentError, TypeError
          nil
        end

        def line_live_equity_wallet_unreal(snap, w)
          d = dual_futures_account_metrics(snap)
          return muted('—') unless d.is_a?(Hash)

          join_compact(
            w,
            [
              live_account_pair_label('EQ', d[:eq_inr], d[:eq_usdt]),
              live_account_pair_label('WAL', d[:wal_inr], d[:wal_usdt]),
              live_account_pair_label('UR', d[:ur_inr], d[:ur_usdt])
            ]
          )
        end

        def live_account_pair_label(tag, inr_amt, usdt_amt)
          "#{bold("#{tag}: ")}#{colored_inr(inr_amt)}#{muted(" (#{fmt_num(usdt_amt)} USDT)")}"
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

        def clr(content)
          "#{content}\e[K"
        end
      end
    end
  end
end
