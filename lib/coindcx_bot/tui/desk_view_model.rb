# frozen_string_literal: true

require 'bigdecimal'

module CoindcxBot
  module Tui
    # Maps {Engine#snapshot} + {TickStore#snapshot} into row-oriented desk data. Rendering stays dumb.
    class DeskViewModel
      INNER_HEIGHT = 6

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
        INNER_HEIGHT
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

      def paper_slippage_total
        pm = @snap.paper_metrics
        return nil unless pm.is_a?(Hash) && pm.key?(:total_slippage)

        pm[:total_slippage]
      end

      private

      def daily_loss_limit_inr
        v = @config.risk[:max_daily_loss_inr]
        return nil if v.nil?

        BigDecimal(v.to_s)
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

      def execution_row_for(sym, pos_by_pair)
        p = pos_by_pair[sym]
        ltp_bd = optional_bd(merged_display_ltps[sym])

        if p.nil?
          return {
            symbol: sym,
            side: 'FLAT',
            qty: '—',
            entry: '—',
            ltp: fmt_price(ltp_bd),
            pnl_usdt: nil,
            pnl_label: '—'
          }
        end

        side = position_side_label(p)
        qty = (p[:quantity] || p['quantity']).to_s
        entry = optional_bd(p[:entry_price] || p['entry_price'])
        u = unrealized_usdt(p, ltp_bd)
        {
          symbol: sym,
          side: side,
          qty: qty,
          entry: fmt_price(entry),
          ltp: fmt_price(ltp_bd),
          pnl_usdt: u,
          pnl_label: fmt_pnl_label(u, p, ltp_bd)
        }
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
        return nil if ltp.nil?

        q = BigDecimal((p[:quantity] || p['quantity']).to_s)
        e = BigDecimal((p[:entry_price] || p['entry_price']).to_s)
        case (p[:side] || p['side']).to_s
        when 'long', 'buy'
          (ltp - e) * q
        when 'short', 'sell'
          (e - ltp) * q
        else
          BigDecimal('0')
        end
      rescue ArgumentError, TypeError
        nil
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
