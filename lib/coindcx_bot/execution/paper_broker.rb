# frozen_string_literal: true

require 'bigdecimal'

module CoindcxBot
  module Execution
    class PaperBroker < Broker
      def initialize(store:, fill_engine:, logger: nil)
        @store = store
        @fill_engine = fill_engine
        @logger = logger
        @order_book = OrderBook.new
        reconcile_order_book
      end

      attr_reader :store, :order_book

      def sync_order_book!
        reconcile_order_book
      end

      # Runs FillEngine against each working order for the pair. Returns an array of result hashes
      # (`:kind` => `:entry` | `:exit`, plus fill / PnL fields). Engine/coordinator wiring (Phase C)
      # should consume these to keep the journal aligned when using deferred working orders.
      def process_tick(pair:, ltp:, high: nil, low: nil)
        return [] if ltp.nil?

        pair_s = pair.to_s
        high_v = coerce_optional_decimal(high)
        low_v = coerce_optional_decimal(low)

        results = []
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

          pos = @store.open_position_for(pair_s)
          if pos && exiting_working_order?(pos, wo)
            summary = finalize_exit_fill(pos: pos, pair: pair_s, fill: fill)
            results << summary.merge(kind: :exit, order_id: order_id, pair: pair_s)
          else
            update_position_from_fill(pair_s, wo.side, fill)
            log_order_filled_event(order_id, pair_s, wo.side, fill, fill_id: fill_id)
            results << { kind: :entry, order_id: order_id, pair: pair_s, side: wo.side, fill: fill }
          end

          @logger&.info("[paper] tick fill #{fill[:trigger]} #{pair_s} order_id=#{order_id}")
        end
        results
      end

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

      def metrics
        {
          total_fees: @store.total_fees,
          total_slippage: @store.total_slippage,
          total_realized_pnl: @store.total_realized_pnl,
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

      private

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
          stop_price: nil,
          trail_price: nil,
          opened_at: row[:created_at]
        }
      end
    end
  end
end
