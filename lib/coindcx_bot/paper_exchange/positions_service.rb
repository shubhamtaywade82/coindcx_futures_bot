# frozen_string_literal: true

require 'bigdecimal'

module CoindcxBot
  module PaperExchange
    class PositionsService
      def initialize(store:, ledger:, orders_service:)
        @store = store
        @db = store.db
        @ledger = ledger
        @orders = orders_service
      end

      def list(user_id, _filters = {})
        rows = @db.execute(
          <<~SQL,
            SELECT * FROM pe_positions
            WHERE user_id = ? AND status = 'open'
            ORDER BY id
          SQL
          [user_id]
        )
        { positions: rows.map { |r| serialize_position(r) } }
      end

      def update_leverage(user_id, attrs)
        pid = (attrs['id'] || attrs[:id]).to_s
        lev = Integer(attrs['leverage'] || attrs[:leverage] || 1)
        row = @db.get_first_row(
          "SELECT * FROM pe_positions WHERE user_id = ? AND id = ? AND status = 'open'",
          [user_id, pid.to_i]
        )
        return { error: 'not_found' } unless row

        @db.execute(
          'UPDATE pe_positions SET leverage = ?, updated_at = ? WHERE id = ?',
          [lev, @store.now_iso, row['id']]
        )
        { id: pid, leverage: lev, status: 'ok' }
      end

      def add_margin(user_id, attrs)
        adjust_isolated_margin(user_id, attrs, :add)
      end

      def remove_margin(user_id, attrs)
        adjust_isolated_margin(user_id, attrs, :remove)
      end

      def cancel_all_open_orders(user_id, attrs)
        pair = attrs['pair'] || attrs[:pair]
        n = cancel_scope(user_id, pair: pair)
        { cancelled: n }
      end

      def cancel_all_open_orders_for_position(user_id, attrs)
        pid = (attrs['id'] || attrs[:id]).to_s
        row = @db.get_first_row(
          "SELECT pair FROM pe_positions WHERE user_id = ? AND id = ? AND status = 'open'",
          [user_id, pid.to_i]
        )
        return { cancelled: 0 } unless row

        n = cancel_scope(user_id, pair: row['pair'])
        { cancelled: n, position_id: pid }
      end

      def exit_position(user_id, attrs)
        pid = (attrs['id'] || attrs[:id]).to_s
        row = @db.get_first_row(
          "SELECT * FROM pe_positions WHERE user_id = ? AND id = ? AND status = 'open'",
          [user_id, pid.to_i]
        )
        return { error: 'not_found' } unless row

        res = @orders.close_position_market!(user_id, row)
        res.merge(id: pid, status: 'ok')
      end

      def create_tpsl(user_id, attrs)
        pid = (attrs['id'] || attrs[:id]).to_s
        {
          id: pid,
          status: 'accepted',
          message: 'paper exchange: TPSL stub; extend with reduce-only trigger orders'
        }
      end

      def list_transactions(user_id, _filters = {})
        rows = @db.execute(
          <<~SQL,
            SELECT * FROM pe_position_margin_events WHERE position_id IN (
              SELECT id FROM pe_positions WHERE user_id = ?
            ) ORDER BY id DESC LIMIT 200
          SQL
          [user_id]
        )
        { transactions: rows.map(&:to_h) }
      end

      def cross_margin_details(user_id)
        snap = @ledger.futures_wallet_snapshot(user_id)
        {
          cross_order_margin: snap[:cross_order_margin].to_s('F'),
          cross_user_margin: snap[:cross_user_margin].to_s('F')
        }
      end

      def update_margin_type(user_id, attrs)
        pid = (attrs['id'] || attrs[:id]).to_s
        mode = (attrs['margin_type'] || attrs[:marginType] || 'cross').to_s
        @db.execute(
          "UPDATE pe_positions SET margin_mode = ?, updated_at = ? WHERE user_id = ? AND id = ?",
          [mode, @store.now_iso, user_id, pid.to_i]
        )
        { id: pid, margin_mode: mode }
      end

      private

      def cancel_scope(user_id, pair:)
        ph = OPEN_STATUSES.map { '?' }.join(', ')
        sql = "SELECT * FROM pe_orders WHERE user_id = ? AND status IN (#{ph})"
        args = [user_id, *OPEN_STATUSES]
        if pair
          sql += ' AND pair = ?'
          args << pair.to_s
        end
        rows = @db.execute(sql, args)
        rows.each { |r| @orders.cancel(user_id, { 'id' => r['id'] }) }
        rows.size
      end

      def adjust_isolated_margin(user_id, attrs, dir)
        pid = (attrs['id'] || attrs[:id]).to_s
        amt = BigDecimal((attrs['amount'] || attrs[:amount] || 0).to_s)
        row = @db.get_first_row(
          "SELECT * FROM pe_positions WHERE user_id = ? AND id = ? AND status = 'open'",
          [user_id, pid.to_i]
        )
        return { error: 'not_found' } unless row

        case dir
        when :add
          @ledger.post_batch!(
            user_id: user_id,
            memo: 'add_margin',
            lines: {
              Ledger::ACCOUNT_FUTURES_AVAILABLE => -amt,
              Ledger::ACCOUNT_FUTURES_CROSS_USER_MARGIN => amt
            }
          )
          new_m = BigDecimal(row['isolated_margin'].to_s) + amt
        when :remove
          @ledger.post_batch!(
            user_id: user_id,
            memo: 'remove_margin',
            lines: {
              Ledger::ACCOUNT_FUTURES_CROSS_USER_MARGIN => -amt,
              Ledger::ACCOUNT_FUTURES_AVAILABLE => amt
            }
          )
          new_m = BigDecimal(row['isolated_margin'].to_s) - amt
        end

        @db.execute(
          'INSERT INTO pe_position_margin_events (position_id, kind, amount, created_at) VALUES (?, ?, ?, ?)',
          [row['id'], dir.to_s, amt.to_s('F'), @store.now_iso]
        )
        @db.execute(
          'UPDATE pe_positions SET isolated_margin = ?, updated_at = ? WHERE id = ?',
          [new_m.to_s('F'), @store.now_iso, row['id']]
        )
        { id: pid, isolated_margin: new_m.to_s('F') }
      end

      def serialize_position(row)
        {
          id: row['id'].to_s,
          pair: row['pair'],
          side: row['side'],
          total_quantity: row['quantity'],
          quantity: row['quantity'],
          average_entry_price: row['avg_entry_price'],
          leverage: row['leverage'].to_i,
          margin_mode: row['margin_mode'],
          isolated_margin: row['isolated_margin'],
          maintenance_margin: row['maintenance_margin'],
          liquidation_price: row['liquidation_price'],
          unrealized_pnl: '0',
          status: row['status']
        }
      end
    end
  end
end
