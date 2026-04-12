# frozen_string_literal: true

require 'bigdecimal'

module CoindcxBot
  module Tui
    # Maps {Engine#snapshot} + {TickStore#snapshot} into row-oriented desk data. Rendering stays dumb.
    class DeskViewModel
      INNER_HEIGHT_MIN = 6
      INNER_HEIGHT_CAP = 24

      def self.build(engine:, tick_store:, symbols:)
        new(
          snapshot: engine.snapshot,
          tick_ticks: tick_store.snapshot,
          symbols: Array(symbols).map(&:to_s),
          ws_stale_fn: ->(sym) { engine.ws_feed_stale?(sym) },
          config: engine.config
        )
      end

      def initialize(snapshot:, tick_ticks:, symbols:, ws_stale_fn:, config:)
        @snap = snapshot
        @tick_ticks = tick_ticks
        @symbols = symbols
        @ws_stale_fn = ws_stale_fn
        @config = config
      end

      def inner_height
        n = @symbols.size
        [[n, INNER_HEIGHT_MIN].max, INNER_HEIGHT_CAP].min
      end

      def execution_rows
        pos_by_pair = index_positions(@snap.positions)
        @symbols.map { |sym| execution_row_for(sym, pos_by_pair) }
      end

      def order_flow_rows
        now = Time.now
        Array(@snap.working_orders).map { |o| order_flow_row(o, now) }
      end

      def depth_rows(now: Time.now)
        @symbols.map { |sym| depth_row(sym, now) }
      end

      def last_event_type
        ev = Array(@snap.recent_events).last
        return '—' unless ev

        ev[:type].to_s.upcase
      end

      def risk_band
        kill = @snap.kill_switch
        return 'CRIT' if kill

        max_loss = daily_loss_limit_inr
        pnl = @snap.daily_pnl
        return 'LOW' if max_loss.nil? || max_loss <= 0

        loss = pnl.negative? ? -pnl : BigDecimal('0')
        util = (loss / max_loss)
        return 'HIGH' if util >= BigDecimal('0.85')
        return 'MED' if util >= BigDecimal('0.5')

        'LOW'
      end

      def drawdown_pct
        cap = @snap.capital_inr
        return nil if cap.nil? || cap.zero?

        ((@snap.daily_pnl / cap) * 100).round(2)
      end

      def loss_utilization_pct
        max_loss = daily_loss_limit_inr
        return nil if max_loss.nil? || max_loss <= 0

        pnl = @snap.daily_pnl
        loss = pnl.negative? ? -pnl : BigDecimal('0')
        # Float for stable "%" display (BigDecimal#to_s can use exponent form for some values).
        ((loss / max_loss) * 100).round(1).to_f
      end

      def strategy_name
        (@config.strategy[:name] || 'trend_continuation').to_s.upcase
      end

      # Journal positions (open trades), for the SIGNAL + STRATEGY strip.
      def strategy_position_state
        return 'PAUSED' if @snap.paused
        return 'KILL' if @snap.kill_switch

        pos = Array(@snap.positions)
        return 'FLAT' if pos.empty?
        return "#{position_side_label(pos.first)} #{compact_pair_symbol((pos.first[:pair] || pos.first['pair']).to_s)}" if pos.size == 1

        "#{pos.size} OPEN"
      end

      # Last engine-cycle evaluation per configured pair (hold reasons = strategy is working; flips are rare).
      def trading_mode_label
        @config.trading_mode_label
      end

      def configured_leverage_label
        od = @config.execution[:order_defaults] || {}
        a = optional_positive_int(od[:leverage] || od['leverage'])
        b = optional_positive_int(@config.risk[:max_leverage])
        return '—' if a.nil? && b.nil?

        v = [a, b].compact.min
        return '—' if v.nil? || v <= 0

        "#{v}x"
      end

      def grid_sidebar_lines
        pos_n = Array(@snap.positions).size
        ord_n = Array(@snap.working_orders).size
        dd = drawdown_pct
        dd_s = dd.nil? ? '—' : format('%+.2f%%', dd.to_f)
        u = loss_utilization_pct
        u_s = u.nil? ? '—' : format('%.1f%%', u.to_f)
        sig = strategy_signal_summary
        sig = sig.length > 68 ? "#{sig[0, 65]}…" : sig
        [
          "DD #{dd_s} │ #{risk_band} │ UTIL #{u_s} │ #{trading_mode_label}",
          "OPEN #{pos_n} │ ORD #{ord_n} │ #{strategy_name}",
          "#{strategy_position_state} │ #{sig}"
        ]
      end

      def strategy_signal_summary
        return '—' if @snap.paused || @snap.kill_switch

        raw = @snap.strategy_last_by_pair
        h = raw.is_a?(Hash) ? raw : {}
        return '—' if h.empty?

        parts = @symbols.filter_map do |sym|
          row = h[sym] || h[sym.to_s]
          next unless row

          act = (row[:action] || row['action']).to_sym
          reason = (row[:reason] || row['reason']).to_s
          cs = compact_pair_symbol(sym)
          if act == :hold
            "#{cs}:#{reason}"
          else
            "#{act.to_s.upcase}@#{cs}"
          end
        end
        return '—' if parts.empty?

        line = parts.join(' · ')
        line.length > 120 ? "#{line[0, 117]}…" : line
      end

      def paper_slippage_total
        pm = @snap.paper_metrics
        return nil unless pm.is_a?(Hash) && pm.key?(:total_slippage)

        pm[:total_slippage]
      end

      private

      def optional_positive_int(raw)
        return nil if raw.nil? || raw.to_s.strip.empty?

        Integer(raw)
      rescue ArgumentError, TypeError
        nil
      end

      def compact_pair_symbol(pair)
        pair.to_s.sub(/^B-/, '').sub(/_USDT\z/i, '')
      end

      def daily_loss_limit_inr
        BigDecimal(@config.resolved_max_daily_loss_inr.to_s)
      rescue ArgumentError, TypeError
        nil
      end

      def index_positions(positions)
        Array(positions).each_with_object({}) do |p, h|
          pair = (p[:pair] || p['pair']).to_s
          h[pair] = p
        end
      end

      def merged_display_ltps
        @merged_display_ltps ||= CoindcxBot::DisplayLtp.merge_prices_by_pair(
          @symbols,
          tick_store_snapshot: @tick_ticks,
          tracker_tick_hash: @snap.ticks
        )
      end

      def mark_price_bd_for_sym(sym)
        tick = @tick_ticks[sym]
        m = optional_bd(tick&.mark)
        return m if m

        optional_bd(merged_display_ltps[sym])
      end

      def execution_row_for(sym, pos_by_pair)
        p = pos_by_pair[sym]
        ltp_bd = optional_bd(merged_display_ltps[sym])
        mark_bd = mark_price_bd_for_sym(sym)

        if p.nil?
          last_s = fmt_price(ltp_bd)
          return {
            symbol: sym,
            side: 'FLAT',
            qty: '—',
            entry: '—',
            ltp: last_s,
            last: last_s,
            mark: fmt_price(mark_bd),
            sl: '—',
            liq: '—',
            pnl_usdt: nil,
            pnl_label: '—'
          }
        end

        side = position_side_label(p)
        qty = (p[:quantity] || p['quantity']).to_s
        entry = optional_bd(p[:entry_price] || p['entry_price'])
        u = unrealized_usdt(p, mark_bd)
        last_s = fmt_price(ltp_bd)
        {
          symbol: sym,
          side: side,
          qty: qty,
          entry: fmt_price(entry),
          ltp: last_s,
          last: last_s,
          mark: fmt_price(mark_bd),
          sl: fmt_stop_price(p),
          liq: '—',
          pnl_usdt: u,
          pnl_label: fmt_pnl_label(u, p, mark_bd)
        }
      end

      def fmt_stop_price(p)
        sp = p[:stop_price] || p['stop_price']
        return '—' if sp.nil? || sp.to_s.strip.empty?

        fmt_price(optional_bd(sp))
      end

      def position_side_label(p)
        s = (p[:side] || p['side']).to_s.downcase
        return 'LONG' if %w[long buy].include?(s)
        return 'SHORT' if %w[short sell].include?(s)

        s.upcase
      end

      def fmt_pnl_label(u, p, ltp_bd)
        return '—' if u.nil?

        pct = unrealized_pct_str(p, ltp_bd)
        "#{fmt_num(u)} (#{pct})"
      end

      def order_flow_row(o, now)
        {
          type_abbr: abbrev_order_type(o[:order_type]),
          symbol: o[:pair].to_s,
          status: 'ACTIVE',
          latency: order_working_age_ms(o, now)
        }
      end

      # Wall-clock age since the order row was created (resting / working latency), not exchange ACK.
      def order_working_age_ms(o, now)
        raw = o[:placed_at] || o['placed_at']
        return nil if raw.nil? || raw.to_s.strip.empty?

        t = Time.iso8601(raw.to_s)
        ms = ((now - t) * 1000).round
        ms.negative? ? 0 : ms
      rescue ArgumentError, TypeError
        nil
      end

      def abbrev_order_type(raw)
        t = raw.to_s.downcase
        return 'MKT' if t.include?('market')
        return 'LIM' if t.include?('limit')
        return 'TP' if t.include?('take') || t.include?('profit')
        return 'SL' if t.include?('stop')

        t.empty? ? '—' : t[0, 3].upcase
      end

      def depth_row(sym, now)
        tick = @tick_ticks[sym]
        ws_stale = @ws_stale_fn.call(sym)
        chg = tick&.change_pct
        chg_s = chg ? format('%+.2f%%', chg.to_f) : '—'
        if tick
          age = (now - tick.updated_at).to_f
          age_s = format('%.2fs', age)
          state = depth_state(ws_stale, age)
        else
          age_s = '—'
          state = ws_stale ? 'STALE' : 'NO_QUOTE'
        end

        {
          symbol: sym,
          bid: fmt_depth_price(tick&.bid),
          ask: fmt_depth_price(tick&.ask),
          spread: fmt_spread(tick),
          chg_pct: chg_s,
          age: age_s,
          state: state,
          ltp: tick ? format('%.2f', tick.ltp.to_f) : '—'
        }
      end

      def fmt_depth_price(v)
        return '—' if v.nil?

        format('%.2f', v.to_f)
      end

      def fmt_spread(tick)
        return '—' unless tick&.bid && tick&.ask

        b = tick.bid.to_f
        a = tick.ask.to_f
        return '—' if a < b

        format('%.2f', a - b)
      end

      def depth_state(ws_stale, age_sec)
        return 'STALE' if ws_stale
        return 'STALE' if age_sec > 1.0
        return 'LAG' if age_sec > 0.3

        'LIVE'
      end

      def optional_bd(v)
        return nil if v.nil? || v.to_s.strip.empty?

        BigDecimal(v.to_s)
      rescue ArgumentError, TypeError
        nil
      end

      def fmt_price(v)
        return '—' if v.nil?

        format('%.2f', v)
      end

      def fmt_num(v)
        format('%+.2f', v)
      end

      def unrealized_usdt(p, ltp)
        CoindcxBot::Strategy::UnrealizedPnl.position_usdt(p, ltp)
      end

      def unrealized_pct_str(p, ltp)
        return '—' if ltp.nil?

        e = BigDecimal((p[:entry_price] || p['entry_price']).to_s)
        return '0%' if e.zero?

        pct =
          case (p[:side] || p['side']).to_s
          when 'long', 'buy'
            ((ltp - e) / e) * 100
          when 'short', 'sell'
            ((e - ltp) / e) * 100
          else
            BigDecimal('0')
          end
        format('%+.2f%%', pct)
      rescue ArgumentError, TypeError
        '—'
      end
    end
  end
end
