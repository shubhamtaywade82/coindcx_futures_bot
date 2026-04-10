# frozen_string_literal: true

require 'bigdecimal'
require 'securerandom'

module CoindcxBot
  module PaperExchange
    OPEN_STATUSES = %w[open partially_filled working triggered].freeze

    class OrdersService
      MAX_OPEN_PER_PAIR = 25

      def initialize(store:, ledger:, market_rules:, fill_engine:)
        @store = store
        @db = store.db
        @ledger = ledger
        @market_rules = market_rules
        @fill_engine = fill_engine
      end

      def create(user_id, order_hash)
        o = normalize_order(order_hash)
        pair = o[:pair].to_s
        @market_rules.validate_order_type!(pair, o[:order_type])
        qty = @market_rules.validate_quantity!(pair, o[:quantity])
        cid = o[:client_order_id].to_s
        raise MarketRules::ValidationError, 'client_order_id required' if cid.empty?

        dup = @db.get_first_row(
          'SELECT id FROM pe_orders WHERE user_id = ? AND client_order_id = ?',
          [user_id, cid]
        )
        raise MarketRules::ValidationError, 'duplicate client_order_id' if dup

        open_count = open_order_count(user_id, pair)
        raise MarketRules::ValidationError, 'max open orders per market (25)' if open_count >= MAX_OPEN_PER_PAIR

        lev = Integer(o[:leverage] || 1)
        lev = 1 if lev < 1

        now = @store.now_iso
        ot = o[:order_type].to_s
        mark = mark_price(pair)

        if ot == 'market_order'
          create_market_filled!(user_id, o, qty, lev, pair, now, mark)
        else
          create_working!(user_id, o, qty, lev, pair, now, ot, mark)
        end
      end

      def cancel(user_id, attrs)
        id = attrs['id'] || attrs[:id]
        cid = attrs['client_order_id'] || attrs[:client_order_id]
        row =
          if id
            @db.get_first_row('SELECT * FROM pe_orders WHERE user_id = ? AND id = ?', [user_id, id.to_i])
          elsif cid
            @db.get_first_row('SELECT * FROM pe_orders WHERE user_id = ? AND client_order_id = ?', [user_id, cid.to_s])
          end
        return { status: 'ignored' } unless row

        st = row['status'].to_s
        return serialize_order(row) if OPEN_STATUSES.exclude?(st)

        release_reserved_margin!(user_id, row)
        @db.execute(
          'UPDATE pe_orders SET status = ?, updated_at = ? WHERE id = ?',
          ['cancelled', @store.now_iso, row['id']]
        )
        log_event('order.cancelled', order_id: row['id'])
        serialize_order(@db.get_first_row('SELECT * FROM pe_orders WHERE id = ?', [row['id']]))
      end

      def list(user_id, filters = {})
        sql = 'SELECT * FROM pe_orders WHERE user_id = ?'
        args = [user_id]
        if (pair = filters['pair'] || filters[:pair])
          sql += ' AND pair = ?'
          args << pair.to_s
        end
        sql += ' ORDER BY id DESC LIMIT 500'
        rows = @db.execute(sql, args)
        { orders: rows.map { |r| serialize_order(r) } }
      end

      def open_order_count(user_id, pair)
        ph = OPEN_STATUSES.map { '?' }.join(', ')
        row = @db.get_first_row(
          "SELECT COUNT(*) AS c FROM pe_orders WHERE user_id = ? AND pair = ? AND status IN (#{ph})",
          [user_id, pair.to_s, *OPEN_STATUSES]
        )
        row['c'].to_i
      end

      def close_position_market!(user_id, position_row)
        pair = position_row['pair']
        mark = mark_price(pair)
        qty = BigDecimal(position_row['quantity'].to_s)
        exit_side = position_row['side'].to_s == 'long' ? 'sell' : 'buy'
        fill = @fill_engine.fill_market_order(side: exit_side, quantity: qty, ltp: mark)
        fee = fill[:fee]
        entry = BigDecimal(position_row['avg_entry_price'].to_s)
        pnl_gross = compute_pnl(position_row['side'], entry, fill[:fill_price], qty)
        pnl_net = pnl_gross - fee
        ensure_funds!(user_id, fee)
        apply_position_close!(user_id, position_row, qty, fill[:fill_price], fee, @store.now_iso)
        {
          ok: true,
          exit_price: fill[:fill_price],
          fee: fee,
          fill_price: fill[:fill_price],
          realized_pnl_usdt: pnl_net
        }
      end

      def process_tick(user_id, pair:, ltp:, high:, low:)
        p = pair.to_s
        rows = @db.execute(
          <<~SQL,
            SELECT * FROM pe_orders
            WHERE user_id = ? AND pair = ? AND status IN (#{OPEN_STATUSES.map { '?' }.join(', ')})
          SQL
          [user_id, p, *OPEN_STATUSES]
        )

        results = []
        rows.each do |row|
          wo = working_order_from_row(row)
          fill = @fill_engine.evaluate(wo, ltp: ltp, high: high, low: low)
          next unless fill

          apply_fill!(user_id, row, fill, ltp: ltp)
          results << { order_id: row['id'], fill: fill }
        end
        results
      end

      def ensure_funds!(user_id, need)
        free = @ledger.futures_wallet_snapshot(user_id)[:balance]
        raise MarketRules::ValidationError, 'insufficient balance' if free < need
      end

      private

      def normalize_order(raw)
        h = raw.transform_keys(&:to_sym)
        qty = h[:total_quantity] || h[:quantity] || h[:size]
        {
          pair: h[:pair] || h[:instrument],
          side: h[:side].to_s.downcase,
          order_type: (h[:order_type] || 'market_order').to_s,
          quantity: qty,
          leverage: h[:leverage],
          client_order_id: h[:client_order_id] || h[:clientOrderId],
          limit_price: h[:limit_price] || h[:price],
          stop_price: h[:stop_price] || h[:stop_price]
        }
      end

      def mark_price(pair)
        row = @db.get_first_row('SELECT ltp FROM pe_mark_prices WHERE pair = ?', [pair.to_s])
        raise MarketRules::ValidationError, 'no mark price; call simulation tick first' unless row

        BigDecimal(row['ltp'].to_s)
      end

      def create_market_filled!(user_id, o, qty, lev, pair, now, mark)
        side = o[:side]
        fill = @fill_engine.fill_market_order(side: side, quantity: qty, ltp: mark)
        fee = fill[:fee]
        pos = find_open_position(user_id, pair)
        entry_side = api_side_to_position_side(side)

        if pos && pos['side'] != entry_side
          ensure_funds!(user_id, fee)
          margin = BigDecimal('0')
        else
          margin = (fill[:fill_price] * qty) / BigDecimal(lev)
          ensure_funds!(user_id, margin + fee)
        end

        @db.execute(
          <<~SQL,
            INSERT INTO pe_orders (
              user_id, client_order_id, pair, side, order_type, order_stage, status,
              price, limit_price, stop_price, total_quantity, remaining_quantity, avg_fill_price,
              leverage, margin_mode, fee_paid, reserved_margin, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, 'standard', 'filled', ?, NULL, NULL, ?, '0', ?, ?, 'cross', ?, '0', ?, ?)
          SQL
            [
            user_id, o[:client_order_id], pair, side, o[:order_type],
            fill[:fill_price].to_s('F'), qty.to_s('F'),
            fill[:fill_price].to_s('F'), lev, fee.to_s('F'), now, now
          ]
        )
        oid = @db.last_insert_row_id

        @db.execute(
          <<~SQL,
            INSERT INTO pe_fills (user_id, order_id, price, quantity, fee, trigger, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
          SQL
          [
            user_id, oid, fill[:fill_price].to_s('F'), qty.to_s('F'), fee.to_s('F'),
            fill[:trigger].to_s, now
          ]
        )

        if pos && pos['side'] != entry_side
          apply_position_close!(user_id, pos, qty, fill[:fill_price], fee, now)
        else
          @ledger.post_batch!(
            user_id: user_id,
            external_ref: "fill:#{oid}:open",
            memo: 'market_open',
            lines: {
              Ledger::ACCOUNT_FUTURES_AVAILABLE => -(margin + fee),
              Ledger::ACCOUNT_FUTURES_CROSS_USER_MARGIN => margin,
              Ledger::ACCOUNT_FEES => fee
            }
          )
          merge_or_open_position!(user_id, pair, side, qty, fill[:fill_price], lev, margin, now)
        end

        log_event('order.filled', order_id: oid, pair: pair)
        serialize_order(@db.get_first_row('SELECT * FROM pe_orders WHERE id = ?', [oid]))
      end

      def find_open_position(user_id, pair)
        @db.get_first_row(
          "SELECT * FROM pe_positions WHERE user_id = ? AND pair = ? AND status = 'open'",
          [user_id, pair.to_s]
        )
      end

      def create_working!(user_id, o, qty, lev, pair, now, ot, mark)
        price = o[:limit_price] || o[:stop_price] || mark
        price = BigDecimal(price.to_s)
        margin = (price * qty) / BigDecimal(lev)
        ensure_funds!(user_id, margin)

        @ledger.post_batch!(
          user_id: user_id,
          external_ref: "reserve:#{o[:client_order_id]}",
          memo: 'order_reserve',
          lines: {
            Ledger::ACCOUNT_FUTURES_AVAILABLE => -margin,
            Ledger::ACCOUNT_FUTURES_LOCKED_ORDER => margin
          }
        )

        @db.execute(
          <<~SQL,
            INSERT INTO pe_orders (
              user_id, client_order_id, pair, side, order_type, order_stage, status,
              price, limit_price, stop_price, total_quantity, remaining_quantity, avg_fill_price,
              leverage, margin_mode, fee_paid, reserved_margin, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, 'standard', 'open', ?, ?, ?, ?, ?, NULL, ?, 'cross', '0', ?, ?, ?)
          SQL
          [
            user_id, o[:client_order_id], pair, side, ot,
            price.to_s('F'),
            (o[:limit_price] ? o[:limit_price].to_s : nil),
            (o[:stop_price] ? o[:stop_price].to_s : nil),
            qty.to_s('F'), qty.to_s('F'), lev, margin.to_s('F'), now, now
          ]
        )
        oid = @db.last_insert_row_id
        log_event('order.accepted', order_id: oid, pair: pair)
        serialize_order(@db.get_first_row('SELECT * FROM pe_orders WHERE id = ?', [oid]))
      end

      def working_order_from_row(row)
        CoindcxBot::Execution::OrderBook::WorkingOrder.new(
          id: row['id'].to_i,
          pair: row['pair'].to_s,
          side: row['side'].to_s,
          order_type: row['order_type'].to_s,
          quantity: BigDecimal(row['remaining_quantity'].to_s),
          anchor_price: nil,
          limit_price: row['limit_price'] ? BigDecimal(row['limit_price'].to_s) : nil,
          stop_price: row['stop_price'] ? BigDecimal(row['stop_price'].to_s) : nil,
          group_id: nil,
          group_role: nil,
          placed_at: nil
        )
      end

      def apply_fill!(user_id, row, fill, ltp:)
        oid = row['id'].to_i
        qty = BigDecimal(row['remaining_quantity'].to_s)
        fill_qty = [qty, fill[:quantity]].min
        fee = fill[:fee] * (fill_qty / fill[:quantity])
        lev = Integer(row['leverage'].to_s)
        margin = (fill[:fill_price] * fill_qty) / BigDecimal(lev)
        now = @store.now_iso

        release_reserved_margin!(user_id, row, partial: fill_qty / qty)

        pos = find_open_position(user_id, row['pair'])
        entry_side = api_side_to_position_side(row['side'])
        closing = pos && pos['side'] != entry_side

        if closing
          ensure_funds!(user_id, fee)
          apply_position_close!(user_id, pos, fill_qty, fill[:fill_price], fee, now)
        else
          @ledger.post_batch!(
            user_id: user_id,
            external_ref: "fill:#{oid}:#{SecureRandom.hex(4)}",
            memo: 'limit_open',
            lines: {
              Ledger::ACCOUNT_FUTURES_AVAILABLE => -(margin + fee),
              Ledger::ACCOUNT_FUTURES_CROSS_USER_MARGIN => margin,
              Ledger::ACCOUNT_FEES => fee
            }
          )
          merge_or_open_position!(user_id, row['pair'], row['side'], fill_qty, fill[:fill_price], lev, margin, now)
        end

        @db.execute(
          <<~SQL,
            INSERT INTO pe_fills (user_id, order_id, price, quantity, fee, trigger, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
          SQL
          [
            user_id, oid, fill[:fill_price].to_s('F'), fill_qty.to_s('F'), fee.to_s('F'),
            fill[:trigger].to_s, now
          ]
        )

        new_rem = qty - fill_qty
        new_status = new_rem.zero? ? 'filled' : 'partially_filled'
        paid = BigDecimal(row['fee_paid'].to_s) + fee
        @db.execute(
          <<~SQL,
            UPDATE pe_orders SET remaining_quantity = ?, status = ?, avg_fill_price = ?, fee_paid = ?, updated_at = ?
            WHERE id = ?
          SQL
          [new_rem.to_s('F'), new_status, fill[:fill_price].to_s('F'), paid.to_s('F'), now, oid]
        )

        log_event(new_rem.zero? ? 'order.filled' : 'order.partially_filled', order_id: oid)
      end

      def release_reserved_margin!(user_id, row, partial: BigDecimal('1'))
        res = BigDecimal(row['reserved_margin'].to_s)
        return if res.zero?

        release = res * partial
        @ledger.post_batch!(
          user_id: user_id,
          memo: 'release_reserve',
          lines: {
            Ledger::ACCOUNT_FUTURES_LOCKED_ORDER => -release,
            Ledger::ACCOUNT_FUTURES_AVAILABLE => release
          }
        )
        new_res = res - release
        @db.execute(
          'UPDATE pe_orders SET reserved_margin = ?, updated_at = ? WHERE id = ?',
          [new_res.to_s('F'), @store.now_iso, row['id']]
        )
      end

      def merge_or_open_position!(user_id, pair, side, qty, price, lev, margin, now)
        pos = find_open_position(user_id, pair)
        pos_side = api_side_to_position_side(side)

        if pos.nil?
          @db.execute(
            <<~SQL,
              INSERT INTO pe_positions (
                user_id, pair, side, quantity, avg_entry_price, leverage, margin_mode,
                isolated_margin, maintenance_margin, liquidation_price, realized_pnl_session, status, created_at, updated_at
              ) VALUES (?, ?, ?, ?, ?, ?, 'cross', ?, '0', NULL, '0', 'open', ?, ?)
            SQL
            [
              user_id, pair, pos_side, qty.to_s('F'), price.to_s('F'), lev, margin.to_s('F'), now, now
            ]
          )
          log_event('position.opened', pair: pair, side: pos_side)
          return
        end

        old_q = BigDecimal(pos['quantity'].to_s)
        old_e = BigDecimal(pos['avg_entry_price'].to_s)
        old_m = BigDecimal(pos['isolated_margin'].to_s)
        new_q = old_q + qty
        new_e = ((old_e * old_q) + (price * qty)) / new_q
        new_m = old_m + margin

        @db.execute(
          <<~SQL,
            UPDATE pe_positions SET quantity = ?, avg_entry_price = ?, isolated_margin = ?, updated_at = ?
            WHERE id = ?
          SQL
          [new_q.to_s('F'), new_e.to_s('F'), new_m.to_s('F'), now, pos['id']]
        )
        log_event('position.updated', position_id: pos['id'])
      end

      def apply_position_close!(user_id, pos, close_qty, exit_price, fee, now)
        pos_q = BigDecimal(pos['quantity'].to_s)
        close_q = [BigDecimal(close_qty.to_s), pos_q].min
        entry = BigDecimal(pos['avg_entry_price'].to_s)
        lev = Integer(pos['leverage'].to_s)
        released_margin = (entry * close_q) / BigDecimal(lev)
        pnl = compute_pnl(pos['side'], entry, exit_price, close_q)
        net = pnl - fee

        lines = {
          Ledger::ACCOUNT_FUTURES_CROSS_USER_MARGIN => -released_margin,
          Ledger::ACCOUNT_FUTURES_AVAILABLE => (released_margin + net),
          Ledger::ACCOUNT_FEES => fee,
          Ledger::ACCOUNT_EQUITY => -pnl
        }
        sum = lines.values.sum
        raise Ledger::InvariantError, "unbalanced close #{sum}" unless sum.abs < BigDecimal('1e-9')

        @ledger.post_batch!(
          user_id: user_id,
          external_ref: "close:#{pos['id']}:#{SecureRandom.hex(4)}",
          memo: 'position_close',
          lines: lines
        )

        prev_real = BigDecimal(pos['realized_pnl_session'].to_s)
        new_real = prev_real + pnl

        remaining = pos_q - close_q
        if remaining.zero?
          @db.execute(
            <<~SQL,
              UPDATE pe_positions SET status = 'closed', quantity = '0', realized_pnl_session = ?, updated_at = ?
              WHERE id = ?
            SQL
            [new_real.to_s('F'), now, pos['id']]
          )
          log_event('position.closed', position_id: pos['id'])
        else
          new_margin = BigDecimal(pos['isolated_margin'].to_s) - released_margin
          @db.execute(
            <<~SQL,
              UPDATE pe_positions SET quantity = ?, isolated_margin = ?, realized_pnl_session = ?, updated_at = ?
              WHERE id = ?
            SQL
            [remaining.to_s('F'), new_margin.to_s('F'), new_real.to_s('F'), now, pos['id']]
          )
          log_event('position.updated', position_id: pos['id'])
        end
      end

      def compute_pnl(side, entry, exit_p, qty)
        case side.to_s
        when 'long'
          (exit_p - entry) * qty
        when 'short'
          (entry - exit_p) * qty
        else
          BigDecimal('0')
        end
      end

      def api_side_to_position_side(side)
        s = side.to_s.downcase
        case s
        when 'buy' then 'long'
        when 'sell' then 'short'
        else s
        end
      end

      def serialize_order(row)
        {
          id: row['id'].to_s,
          client_order_id: row['client_order_id'],
          pair: row['pair'],
          side: row['side'],
          order_type: row['order_type'],
          order_stage: row['order_stage'],
          status: row['status'],
          price: row['price'],
          limit_price: row['limit_price'],
          stop_price: row['stop_price'],
          total_quantity: row['total_quantity'],
          remaining_quantity: row['remaining_quantity'],
          avg_price: row['avg_fill_price'],
          leverage: row['leverage'].to_i,
          fee_amount: row['fee_paid'],
          margin_mode: row['margin_mode']
        }
      end

      def log_event(type, payload)
        require 'json'
        @db.execute(
          'INSERT INTO pe_internal_events (event_type, payload, created_at) VALUES (?, ?, ?)',
          [type, JSON.generate(payload), @store.now_iso]
        )
      end
    end
  end
end
