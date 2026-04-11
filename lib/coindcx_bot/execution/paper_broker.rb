# frozen_string_literal: true

require 'bigdecimal'
require_relative '../strategy/dynamic_trail'

module CoindcxBot
  module Execution
    class PaperBroker < Broker
      # Default funding rate per 8-hour interval (0.01% = 1 bps).
      DEFAULT_FUNDING_RATE_BPS = BigDecimal('1')
      FUNDING_INTERVAL_SECONDS = 8 * 3600
      DYNAMIC_TRAIL_MIN_CANDLES = 16

      def initialize(store:, fill_engine:, logger: nil, funding_rate_bps: nil, trail_config: nil)
        @store = store
        @fill_engine = fill_engine
        @logger = logger
        @trail_config = trail_config || {}
        @order_book = OrderBook.new
        @funding_rate = BigDecimal((funding_rate_bps || DEFAULT_FUNDING_RATE_BPS).to_s) / 10_000
        @last_funding_at = Time.now
        reconcile_order_book
      end

      attr_reader :store, :order_book

      def sync_order_book!
        reconcile_order_book
      end

      # --- Tick processing (fills, OCO, trailing) ---

      # Runs FillEngine against each working order for the pair. Returns an array of result hashes.
      # Handles OCO group cancellation: when SL fills, TP is canceled and vice versa.
      # Also runs trailing stop logic for open positions with active SL working orders.
      def process_tick(pair:, ltp:, high: nil, low: nil, candles: nil)
        return [] if ltp.nil?

        pair_s = pair.to_s
        high_v = coerce_optional_decimal(high)
        low_v = coerce_optional_decimal(low)

        results = []

        # Phase 1: Trail working stops before evaluating fills
        trail_working_stops(pair_s, ltp, high_v, candles)

        # Phase 2: Evaluate working orders for fills
        @order_book.working_for(pair_s).dup.each do |wo|
          fill = @fill_engine.evaluate(wo, ltp: ltp, high: high_v, low: low_v)
          next unless fill

          order_id = wo.id
          fill_id = @store.insert_fill(
            order_id: order_id,
            price: fill[:fill_price],
            quantity: fill[:quantity],
            fee: fill[:fee],
            slippage: fill[:slippage],
            trigger: fill[:trigger].to_s
          )
          @store.update_order_status(order_id, 'filled')
          @order_book.remove(order_id)

          # OCO: cancel sibling orders in the same group
          cancel_oco_siblings(order_id)

          pos = @store.open_position_for(pair_s)
          if pos && exiting_working_order?(pos, wo)
            summary = finalize_exit_fill(pos: pos, pair: pair_s, fill: fill)
            complete_group_for_order(order_id)
            results << summary.merge(kind: :exit, order_id: order_id, pair: pair_s,
                                     trigger: fill[:trigger])
          else
            update_position_from_fill(pair_s, wo.side, fill)
            log_order_filled_event(order_id, pair_s, wo.side, fill, fill_id: fill_id)
            results << { kind: :entry, order_id: order_id, pair: pair_s, side: wo.side,
                         fill: fill, trigger: fill[:trigger] }
          end

          @logger&.info("[paper] tick fill #{fill[:trigger]} #{pair_s} order_id=#{order_id}")
        end

        # Phase 3: Accrue funding fees periodically
        maybe_accrue_funding(pair_s, ltp)

        results
      end

      # --- Order placement ---

      def place_order(order)
        pair = order[:pair]
        side = order[:side].to_s
        quantity = BigDecimal(order[:quantity].to_s)
        ltp = BigDecimal(order[:ltp].to_s)

        order_id = @store.insert_order(
          pair: pair,
          side: side,
          order_type: (order[:order_type] || :market).to_s,
          price: ltp,
          quantity: quantity,
          status: 'accepted'
        )

        fill = @fill_engine.fill_market_order(side: side, quantity: quantity, ltp: ltp)

        fill_id = @store.insert_fill(
          order_id: order_id,
          price: fill[:fill_price],
          quantity: fill[:quantity],
          fee: fill[:fee],
          slippage: fill[:slippage],
          trigger: 'market_order'
        )

        @store.update_order_status(order_id, 'filled')

        update_position_from_fill(pair, side, fill)

        log_order_filled_event(order_id, pair, side, fill, fill_id: fill_id)

        @logger&.info("[paper] filled #{side} #{pair} qty=#{fill[:quantity].to_s('F')} @ #{fill[:fill_price].to_s('F')} fee=#{fill[:fee].to_s('F')}")
        :ok
      end

      # Places an entry order and automatically creates SL (and optional TP) working orders as an OCO group.
      # Returns { ok: true, entry_order_id:, group_id:, fill: } on success.
      def place_bracket_order(order, sl_price:, tp_price: nil)
        pair = order[:pair].to_s
        side = order[:side].to_s
        quantity = BigDecimal(order[:quantity].to_s)
        ltp = BigDecimal(order[:ltp].to_s)

        # 1. Place and fill entry order
        entry_order_id = @store.insert_order(
          pair: pair,
          side: side,
          order_type: (order[:order_type] || :market).to_s,
          price: ltp,
          quantity: quantity,
          status: 'accepted'
        )

        fill = @fill_engine.fill_market_order(side: side, quantity: quantity, ltp: ltp)

        fill_id = @store.insert_fill(
          order_id: entry_order_id,
          price: fill[:fill_price],
          quantity: fill[:quantity],
          fee: fill[:fee],
          slippage: fill[:slippage],
          trigger: 'market_order'
        )

        @store.update_order_status(entry_order_id, 'filled')
        update_position_from_fill(pair, side, fill)
        log_order_filled_event(entry_order_id, pair, side, fill, fill_id: fill_id)

        # 2. Create OCO group
        group_id = @store.insert_order_group(pair: pair, entry_order_id: entry_order_id)

        # 3. Place SL working order (opposite side)
        exit_side = opposite_side(side)
        sl_order_id = place_working_stop(
          pair: pair,
          side: exit_side,
          quantity: quantity,
          stop_price: BigDecimal(sl_price.to_s),
          group_id: group_id,
          group_role: 'stop_loss'
        )
        @store.update_order_group_sl(group_id, sl_order_id)

        # 4. Place TP working order if tp_price provided
        tp_order_id = nil
        if tp_price
          tp_order_id = place_working_take_profit(
            pair: pair,
            side: exit_side,
            quantity: quantity,
            tp_price: BigDecimal(tp_price.to_s),
            group_id: group_id,
            group_role: 'take_profit'
          )
          @store.update_order_group_tp(group_id, tp_order_id)
        end

        # 5. Store stop/trail on position
        pos = @store.open_position_for(pair)
        if pos
          sl_bd = BigDecimal(sl_price.to_s)
          @store.update_position_stop_price(pos[:id], stop_price: sl_bd)
          @store.update_position_initial_stop_price(pos[:id], initial_stop_price: sl_bd)
        end

        @logger&.info("[paper] bracket #{side} #{pair} qty=#{quantity.to_s('F')} @ #{fill[:fill_price].to_s('F')} SL=#{sl_price} TP=#{tp_price || 'none'} group=#{group_id}")

        {
          ok: true,
          entry_order_id: entry_order_id,
          sl_order_id: sl_order_id,
          tp_order_id: tp_order_id,
          group_id: group_id,
          fill: fill
        }
      end

      # --- Trailing stop management ---

      # Updates the working SL order for a pair to a new stop price. Called when the strategy
      # or coordinator decides to trail the stop. Updates both the OrderBook and the store.
      def update_trailing_stop(pair:, new_stop:)
        pair_s = pair.to_s
        new_stop_bd = BigDecimal(new_stop.to_s)

        group = @store.find_active_group_for_pair(pair_s)
        return unless group && group[:sl_order_id]

        sl_id = group[:sl_order_id]
        @order_book.update_stop(sl_id, new_stop_bd)
        @store.update_order_stop_price(sl_id, new_stop_bd)

        pos = @store.open_position_for(pair_s)
        if pos
          @store.update_position_stop_price(pos[:id], stop_price: new_stop_bd)
          @store.update_position_trail_price(pos[:id], trail_price: new_stop_bd)
        end

        @logger&.info("[paper] trail #{pair_s} SL → #{new_stop_bd.to_s('F')}")
      end

      # --- Position management ---

      def cancel_order(order_id)
        @store.update_order_status(order_id, 'canceled')
        @order_book.remove(order_id)
        :ok
      end

      def open_positions
        @store.open_positions.map { |row| normalize_position(row) }
      end

      def open_position_for(pair)
        row = @store.open_position_for(pair)
        return nil unless row

        normalize_position(row)
      end

      def close_position(pair:, side:, quantity:, ltp:, position_id: nil)
        pos = resolve_position(pair, position_id)
        return { ok: false, reason: :no_position } unless pos

        exit_side = opposite_side(pos[:side])
        fill = @fill_engine.fill_market_order(side: exit_side, quantity: quantity, ltp: ltp)

        order_id = @store.insert_order(
          pair: pair,
          side: exit_side,
          order_type: 'market',
          price: ltp,
          quantity: quantity,
          status: 'accepted'
        )

        @store.insert_fill(
          order_id: order_id,
          price: fill[:fill_price],
          quantity: fill[:quantity],
          fee: fill[:fee],
          slippage: fill[:slippage],
          trigger: 'market_order'
        )

        @store.update_order_status(order_id, 'filled')

        # Cancel any remaining working orders for this pair's group
        cancel_active_group_orders(pair)

        summary = finalize_exit_fill(pos: pos, pair: pair, fill: fill.merge(trigger: :market_order))

        @logger&.info("[paper] closed #{pair} pnl=#{summary[:realized_pnl_usdt].to_s('F')} exit=#{fill[:fill_price].to_s('F')}")
        {
          ok: true,
          realized_pnl_usdt: summary[:realized_pnl_usdt],
          fill_price: fill[:fill_price],
          position_id: pos[:id]
        }
      end

      def paper?
        true
      end

      def tui_working_orders
        @order_book.working_snapshot
      end

      # --- Metrics and PnL ---

      def metrics
        {
          total_fees: @store.total_fees,
          total_slippage: @store.total_slippage,
          total_realized_pnl: @store.total_realized_pnl,
          total_funding_fees: @store.total_funding_fees,
          fill_count: @store.fill_count,
          open_positions: @store.open_positions.size,
          order_count: @store.order_count,
          rejected_count: @store.order_count(status: 'rejected'),
          working_orders: @order_book.size
        }
      end

      def unrealized_pnl(ltp_map)
        @store.open_positions.sum(BigDecimal('0')) do |pos|
          pair_ltp = ltp_map[pos[:pair].to_s] || ltp_map[pos[:pair].to_sym]
          next BigDecimal('0') unless pair_ltp

          compute_unrealized(pos, BigDecimal(pair_ltp.to_s))
        end
      end

      # Snapshot current account state for equity curve tracking.
      def record_snapshot(ltp_map)
        realized = @store.total_realized_pnl
        unrealized = unrealized_pnl(ltp_map)
        fees = @store.total_fees
        slippage = @store.total_slippage
        funding = @store.total_funding_fees
        equity = realized + unrealized - funding

        @store.insert_snapshot(
          equity: equity,
          realized_pnl: realized,
          unrealized_pnl: unrealized,
          total_fees: fees,
          total_slippage: slippage
        )
      end

      private

      # --- Trailing stop logic ---

      # Auto-trails working SL orders based on price movement. Uses ATR-style chandelier trail:
      # for longs, trail = max(current_stop, high - trail_distance). Trail only ratchets up (long) or down (short).
      def trail_working_stops(pair, ltp, high, candles = nil)
        group = @store.find_active_group_for_pair(pair)
        return unless group && group[:sl_order_id]

        pos = @store.open_position_for(pair)
        return unless pos

        sl_order = @order_book.find(group[:sl_order_id])
        return unless sl_order

        current_stop = sl_order.stop_price
        return unless current_stop

        entry = BigDecimal(pos[:entry_price].to_s)
        ltp_bd = BigDecimal(ltp.to_s)
        side = pos[:side].to_s

        out = compute_auto_trail(side, entry, current_stop, ltp_bd, high, candles, pos)
        return unless out

        new_stop = out.stop_price
        return if new_stop == current_stop

        @order_book.update_stop(group[:sl_order_id], new_stop)
        @store.update_order_stop_price(group[:sl_order_id], new_stop)
        @store.update_position_stop_price(pos[:id], stop_price: new_stop)
        @store.update_position_trail_price(pos[:id], trail_price: new_stop)
        log_auto_trail(pair, current_stop, new_stop, out)
      end

      def log_auto_trail(pair, old_stop, new_stop, out)
        parts = []
        parts << "tier=#{out.tier}" unless out.tier.nil?
        parts << "v=#{out.v_factor.to_s('F')}" if out.v_factor
        parts << "vol=#{out.vol_factor.to_s('F')}" if out.vol_factor
        suffix = parts.empty? ? '' : " (#{parts.join(', ')})"
        @logger&.info("[paper] auto-trail #{pair} SL #{old_stop.to_s('F')} → #{new_stop.to_s('F')}#{suffix}")
      end

      def trail_calculator
        @trail_calculator ||= Strategy::DynamicTrail::Calculator.new(@trail_config)
      end

      def compute_auto_trail(side, entry, current_stop, ltp, high, candles, pos)
        if candles && candles.size >= DYNAMIC_TRAIL_MIN_CANDLES
          raw_initial = pos[:initial_stop_price] || pos[:stop_price]
          return nil if raw_initial.nil? || raw_initial.to_s.strip.empty?

          side_sym = side.to_s == 'long' || side.to_s == 'buy' ? :long : :short
          output = trail_calculator.call(
            Strategy::DynamicTrail::Input.new(
              side: side_sym,
              candles: candles,
              entry_price: entry,
              initial_stop: BigDecimal(raw_initial.to_s),
              current_stop: current_stop,
              ltp: high || ltp
            )
          )
          return output if output.changed

          return nil
        end

        legacy_auto_trail_output(side, entry, current_stop, ltp, high)
      end

      # Legacy: ratchet stop once > 1R in profit; trail at 50% of profit from entry.
      def legacy_auto_trail_output(side, entry, current_stop, ltp, high)
        new_stop =
          case side
          when 'long', 'buy'
            risk = (entry - current_stop).abs
            return nil if risk <= 0

            ref_price = high || ltp
            profit = ref_price - entry
            return nil if profit < risk

            candidate = entry + (profit * BigDecimal('0.5'))
            candidate > current_stop ? candidate : nil
          when 'short', 'sell'
            risk = (current_stop - entry).abs
            return nil if risk <= 0

            profit = entry - ltp
            return nil if profit < risk

            candidate = entry - (profit * BigDecimal('0.5'))
            candidate < current_stop ? candidate : nil
          end

        return nil if new_stop.nil?

        Strategy::DynamicTrail::Output.new(
          stop_price: new_stop,
          changed: true,
          tier: nil,
          v_factor: nil,
          vol_factor: nil,
          trail_distance: nil,
          reason: 'legacy_trail'
        )
      end

      # --- OCO group management ---

      def cancel_oco_siblings(filled_order_id)
        group = @store.find_group_by_order(filled_order_id)
        return unless group

        @store.sibling_order_ids(group, filled_order_id).each do |sib_id|
          order = @store.find_order(sib_id)
          next unless order && CoindcxBot::Persistence::PaperStore::WORKING_ORDER_STATUSES.include?(order[:status])

          @store.update_order_status(sib_id, 'canceled')
          @order_book.remove(sib_id)
          @logger&.info("[paper] OCO cancel order_id=#{sib_id} (sibling of filled #{filled_order_id})")
        end
      end

      def complete_group_for_order(order_id)
        group = @store.find_group_by_order(order_id)
        return unless group

        @store.complete_order_group(group[:id])
      end

      def cancel_active_group_orders(pair)
        group = @store.find_active_group_for_pair(pair)
        return unless group

        [group[:sl_order_id], group[:tp_order_id]].compact.each do |oid|
          order = @store.find_order(oid)
          next unless order && CoindcxBot::Persistence::PaperStore::WORKING_ORDER_STATUSES.include?(order[:status])

          @store.update_order_status(oid, 'canceled')
          @order_book.remove(oid)
        end
        @store.complete_order_group(group[:id])
      end

      # --- Working order placement helpers ---

      def place_working_stop(pair:, side:, quantity:, stop_price:, group_id:, group_role:)
        order_id = @store.insert_order(
          pair: pair,
          side: side,
          order_type: 'stop_market',
          price: stop_price,
          quantity: quantity,
          status: 'working',
          stop_price: stop_price,
          group_id: group_id,
          group_role: group_role
        )

        @order_book.add(
          order_id,
          pair: pair,
          side: side,
          order_type: 'stop_market',
          quantity: quantity,
          anchor_price: stop_price,
          stop_price: stop_price,
          group_id: group_id,
          group_role: group_role
        )

        order_id
      end

      def place_working_take_profit(pair:, side:, quantity:, tp_price:, group_id:, group_role:)
        order_id = @store.insert_order(
          pair: pair,
          side: side,
          order_type: 'take_profit_market',
          price: tp_price,
          quantity: quantity,
          status: 'working',
          stop_price: tp_price,
          group_id: group_id,
          group_role: group_role
        )

        @order_book.add(
          order_id,
          pair: pair,
          side: side,
          order_type: 'take_profit',
          quantity: quantity,
          anchor_price: tp_price,
          stop_price: tp_price,
          group_id: group_id,
          group_role: group_role
        )

        order_id
      end

      # --- Funding fee accrual ---

      def maybe_accrue_funding(pair, ltp)
        now = Time.now
        return unless (now - @last_funding_at) >= FUNDING_INTERVAL_SECONDS

        @last_funding_at = now
        accrue_funding_for_pair(pair, ltp)
      end

      def accrue_funding_for_pair(pair, ltp)
        pos = @store.open_position_for(pair)
        return unless pos

        ltp_bd = BigDecimal(ltp.to_s)
        qty = BigDecimal(pos[:quantity].to_s)
        position_value = ltp_bd * qty
        fee = (position_value * @funding_rate).abs

        @store.insert_funding_fee(
          pair: pair,
          position_id: pos[:id],
          amount: fee,
          rate: @funding_rate,
          position_value: position_value
        )

        @logger&.info("[paper] funding fee #{pair} #{fee.to_s('F')} USDT (rate=#{@funding_rate.to_s('F')})")
      end

      # --- Shared helpers ---

      def coerce_optional_decimal(v)
        return nil if v.nil?

        BigDecimal(v.to_s)
      rescue ArgumentError, TypeError
        nil
      end

      def exiting_working_order?(pos, wo)
        return false unless pos

        case pos[:side].to_s
        when 'long', 'buy'
          wo.side.to_s.casecmp('sell').zero?
        when 'short', 'sell'
          wo.side.to_s.casecmp('buy').zero?
        else
          false
        end
      end

      def finalize_exit_fill(pos:, pair:, fill:)
        pnl = compute_pnl(pos, fill[:fill_price], fill[:quantity], fill[:fee])

        # Deduct accumulated funding fees from realized PnL
        funding = @store.total_funding_fees(pair: pair)
        pnl -= funding if funding.positive?

        pos_quantity = BigDecimal(pos[:quantity].to_s)
        close_quantity = fill[:quantity]

        if close_quantity >= pos_quantity
          @store.close_position(pos[:id], realized_pnl: pnl)
        else
          remaining = pos_quantity - close_quantity
          @store.reduce_position(pos[:id], new_quantity: remaining, realized_pnl_delta: pnl)
        end

        @store.insert_event(
          event_type: 'position_closed',
          payload: {
            position_id: pos[:id],
            pair: pair,
            side: pos[:side],
            realized_pnl: pnl.to_s('F'),
            exit_price: fill[:fill_price].to_s('F'),
            fee: fill[:fee].to_s('F'),
            funding_fees: funding.to_s('F'),
            trigger: fill[:trigger].to_s
          }
        )

        { realized_pnl_usdt: pnl, fill_price: fill[:fill_price], position_id: pos[:id] }
      end

      def log_order_filled_event(order_id, pair, side, fill, fill_id:)
        @store.insert_event(
          event_type: 'order_filled',
          payload: {
            order_id: order_id,
            fill_id: fill_id,
            pair: pair,
            side: side.to_s,
            fill_price: fill[:fill_price].to_s('F'),
            quantity: fill[:quantity].to_s('F'),
            fee: fill[:fee].to_s('F'),
            slippage: fill[:slippage].to_s('F'),
            trigger: fill[:trigger].to_s
          }
        )
      end

      def reconcile_order_book
        @order_book.reconcile_from_store(@store)
        n = @order_book.size
        @logger&.info("[paper] reconciled #{n} working order(s) from store") if n.positive?
      end

      def update_position_from_fill(pair, side, fill)
        existing = @store.open_position_for(pair)

        if existing.nil? || existing[:side] != side
          @store.insert_position(
            pair: pair,
            side: side,
            quantity: fill[:quantity],
            entry_price: fill[:fill_price]
          )
        else
          existing_qty = BigDecimal(existing[:quantity].to_s)
          existing_entry = BigDecimal(existing[:entry_price].to_s)
          new_qty = existing_qty + fill[:quantity]
          new_entry = ((existing_entry * existing_qty) + (fill[:fill_price] * fill[:quantity])) / new_qty

          @store.reduce_position(
            existing[:id],
            new_quantity: new_qty,
            realized_pnl_delta: BigDecimal('0')
          )
          @store.update_position_entry_price(existing[:id], entry_price: new_entry)
        end
      end

      def resolve_position(pair, position_id)
        if position_id
          @store.find_position(position_id)
        else
          @store.open_position_for(pair)
        end
      end

      def opposite_side(side)
        side.to_s == 'long' || side.to_s == 'buy' ? 'sell' : 'buy'
      end

      def compute_pnl(position, exit_price, exit_quantity, fee)
        entry = BigDecimal(position[:entry_price].to_s)
        pnl =
          case position[:side].to_s
          when 'long', 'buy'
            (exit_price - entry) * exit_quantity
          else
            (entry - exit_price) * exit_quantity
          end
        pnl - fee
      end

      def compute_unrealized(position, current_ltp)
        entry = BigDecimal(position[:entry_price].to_s)
        qty = BigDecimal(position[:quantity].to_s)
        case position[:side].to_s
        when 'long', 'buy'
          (current_ltp - entry) * qty
        else
          (entry - current_ltp) * qty
        end
      end

      def normalize_position(row)
        {
          id: row[:id],
          pair: row[:pair],
          side: row[:side],
          entry_price: row[:entry_price],
          quantity: row[:quantity],
          state: row[:status] == 'open' ? 'open' : 'closed',
          partial_done: 0,
          stop_price: row[:stop_price],
          trail_price: row[:trail_price],
          opened_at: row[:created_at]
        }
      end
    end
  end
end
