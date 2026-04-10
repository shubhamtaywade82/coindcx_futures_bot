# frozen_string_literal: true

require 'sqlite3'
require 'json'
require 'fileutils'
require 'bigdecimal'

module CoindcxBot
  module Persistence
    class PaperStore
      WORKING_ORDER_STATUSES = %w[new working accepted].freeze
      MIGRATE_TABLE_ALLOWLIST = %w[paper_orders paper_fills paper_positions].freeze

      def initialize(path)
        FileUtils.mkdir_p(File.dirname(path))
        @db = SQLite3::Database.new(path)
        @db.results_as_hash = true
        migrate
      end

      def close
        @db.close
      end

      # --- Orders ---

      def insert_order(pair:, side:, order_type:, price:, quantity:, status: 'new',
                     limit_price: nil, stop_price: nil, group_id: nil, group_role: nil, metadata: nil)
        meta =
          case metadata
          when nil then '{}'
          when String then metadata
          else JSON.generate(metadata)
          end
        @db.execute(
          <<~SQL,
            INSERT INTO paper_orders (
              pair, side, order_type, price, quantity, status, created_at, updated_at,
              limit_price, stop_price, group_id, group_role, metadata
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          SQL
          [
            pair, side.to_s, order_type.to_s, bd_str(price), bd_str(quantity), status,
            now_iso, now_iso,
            (limit_price ? bd_str(limit_price) : nil),
            (stop_price ? bd_str(stop_price) : nil),
            group_id,
            group_role&.to_s,
            meta
          ]
        )
        @db.last_insert_row_id
      end

      def update_order_status(id, status)
        @db.execute('UPDATE paper_orders SET status = ?, updated_at = ? WHERE id = ?', [status, now_iso, id])
      end

      def update_order_stop_price(id, stop_price)
        @db.execute(
          'UPDATE paper_orders SET stop_price = ?, updated_at = ? WHERE id = ?',
          [bd_str(stop_price), now_iso, id]
        )
      end

      def find_order(id)
        row = @db.get_first_row('SELECT * FROM paper_orders WHERE id = ?', id)
        symbolize(row)
      end

      def orders_by_pair(pair, status: nil)
        if status
          rows = @db.execute('SELECT * FROM paper_orders WHERE pair = ? AND status = ?', [pair, status])
        else
          rows = @db.execute('SELECT * FROM paper_orders WHERE pair = ?', [pair])
        end
        rows.map { |r| symbolize(r) }
      end

      def all_orders(status: nil)
        rows =
          if status
            @db.execute('SELECT * FROM paper_orders WHERE status = ?', [status])
          else
            @db.execute('SELECT * FROM paper_orders')
          end
        rows.map { |r| symbolize(r) }
      end

      def working_orders(pair: nil)
        placeholders = WORKING_ORDER_STATUSES.map { '?' }.join(', ')
        sql = "SELECT * FROM paper_orders WHERE status IN (#{placeholders})"
        args = WORKING_ORDER_STATUSES.dup
        if pair
          sql += ' AND pair = ?'
          args << pair.to_s
        end
        sql += ' ORDER BY id'
        @db.execute(sql, args).map { |r| symbolize(r) }
      end

      # --- Fills ---

      def insert_fill(order_id:, price:, quantity:, fee:, slippage:, trigger: 'market_order')
        @db.execute(
          <<~SQL,
            INSERT INTO paper_fills (order_id, price, quantity, fee, slippage, trigger, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
          SQL
          [order_id, bd_str(price), bd_str(quantity), bd_str(fee), bd_str(slippage), trigger.to_s, now_iso]
        )
        @db.last_insert_row_id
      end

      def fills_for_order(order_id)
        @db.execute('SELECT * FROM paper_fills WHERE order_id = ?', order_id).map { |r| symbolize(r) }
      end

      def all_fills
        @db.execute('SELECT * FROM paper_fills ORDER BY id').map { |r| symbolize(r) }
      end

      # --- Positions ---

      def insert_position(pair:, side:, quantity:, entry_price:, realized_pnl: BigDecimal('0'))
        @db.execute(
          <<~SQL,
            INSERT INTO paper_positions (pair, side, quantity, entry_price, realized_pnl, status, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, 'open', ?, ?)
          SQL
          [pair, side.to_s, bd_str(quantity), bd_str(entry_price), bd_str(realized_pnl), now_iso, now_iso]
        )
        @db.last_insert_row_id
      end

      def open_position_for(pair)
        row = @db.get_first_row("SELECT * FROM paper_positions WHERE pair = ? AND status = 'open'", pair)
        symbolize(row)
      end

      def open_positions
        @db.execute("SELECT * FROM paper_positions WHERE status = 'open'").map { |r| symbolize(r) }
      end

      def close_position(id, realized_pnl:)
        @db.execute(
          "UPDATE paper_positions SET status = 'closed', realized_pnl = ?, updated_at = ? WHERE id = ?",
          [bd_str(realized_pnl), now_iso, id]
        )
      end

      def reduce_position(id, new_quantity:, realized_pnl_delta:)
        row = @db.get_first_row('SELECT realized_pnl FROM paper_positions WHERE id = ?', id)
        return unless row

        current_pnl = BigDecimal(row['realized_pnl'].to_s)
        updated_pnl = current_pnl + realized_pnl_delta
        @db.execute(
          'UPDATE paper_positions SET quantity = ?, realized_pnl = ?, updated_at = ? WHERE id = ?',
          [bd_str(new_quantity), bd_str(updated_pnl), now_iso, id]
        )
      end

      def update_position_entry_price(id, entry_price:)
        @db.execute(
          'UPDATE paper_positions SET entry_price = ?, updated_at = ? WHERE id = ?',
          [bd_str(entry_price), now_iso, id]
        )
      end

      def find_position(id)
        row = @db.get_first_row('SELECT * FROM paper_positions WHERE id = ?', id)
        symbolize(row)
      end

      def all_positions
        @db.execute('SELECT * FROM paper_positions ORDER BY id').map { |r| symbolize(r) }
      end

      # --- Events ---

      def insert_event(event_type:, payload: {})
        @db.execute(
          'INSERT INTO paper_events (event_type, payload, created_at) VALUES (?, ?, ?)',
          [event_type, JSON.generate(payload), now_iso]
        )
        @db.last_insert_row_id
      end

      def recent_events(limit = 50)
        @db.execute('SELECT * FROM paper_events ORDER BY id DESC LIMIT ?', limit).map { |r| symbolize(r) }
      end

      # --- Account Snapshots ---

      def insert_snapshot(equity:, realized_pnl:, unrealized_pnl:, total_fees:, total_slippage:)
        @db.execute(
          <<~SQL,
            INSERT INTO paper_account_snapshots (equity, realized_pnl, unrealized_pnl, total_fees, total_slippage, created_at)
            VALUES (?, ?, ?, ?, ?, ?)
          SQL
          [bd_str(equity), bd_str(realized_pnl), bd_str(unrealized_pnl), bd_str(total_fees), bd_str(total_slippage), now_iso]
        )
        @db.last_insert_row_id
      end

      def latest_snapshot
        row = @db.get_first_row('SELECT * FROM paper_account_snapshots ORDER BY id DESC LIMIT 1')
        symbolize(row)
      end

      # --- Order Groups (OCO brackets) ---

      def insert_order_group(pair:, entry_order_id:, sl_order_id: nil, tp_order_id: nil)
        @db.execute(
          <<~SQL,
            INSERT INTO paper_order_groups (pair, status, entry_order_id, sl_order_id, tp_order_id, created_at)
            VALUES (?, 'active', ?, ?, ?, ?)
          SQL
          [pair, entry_order_id, sl_order_id, tp_order_id, now_iso]
        )
        @db.last_insert_row_id
      end

      def update_order_group_sl(group_id, sl_order_id)
        @db.execute(
          'UPDATE paper_order_groups SET sl_order_id = ? WHERE id = ?',
          [sl_order_id, group_id]
        )
      end

      def update_order_group_tp(group_id, tp_order_id)
        @db.execute(
          'UPDATE paper_order_groups SET tp_order_id = ? WHERE id = ?',
          [tp_order_id, group_id]
        )
      end

      def find_order_group(id)
        row = @db.get_first_row('SELECT * FROM paper_order_groups WHERE id = ?', id)
        symbolize(row)
      end

      def find_active_group_for_pair(pair)
        row = @db.get_first_row(
          "SELECT * FROM paper_order_groups WHERE pair = ? AND status = 'active' ORDER BY id DESC LIMIT 1",
          pair
        )
        symbolize(row)
      end

      def find_group_by_order(order_id)
        row = @db.get_first_row(
          <<~SQL,
            SELECT * FROM paper_order_groups
            WHERE (entry_order_id = ? OR sl_order_id = ? OR tp_order_id = ?)
              AND status = 'active'
            LIMIT 1
          SQL
          [order_id, order_id, order_id]
        )
        symbolize(row)
      end

      def complete_order_group(id)
        @db.execute(
          "UPDATE paper_order_groups SET status = 'completed', completed_at = ? WHERE id = ?",
          [now_iso, id]
        )
      end

      def sibling_order_ids(group, filled_order_id)
        ids = [group[:entry_order_id], group[:sl_order_id], group[:tp_order_id]].compact
        ids.reject { |oid| oid == filled_order_id }
      end

      # --- Funding Fees ---

      def insert_funding_fee(pair:, position_id:, amount:, rate:, position_value:)
        @db.execute(
          <<~SQL,
            INSERT INTO paper_funding_fees (pair, position_id, amount, rate, position_value, created_at)
            VALUES (?, ?, ?, ?, ?, ?)
          SQL
          [pair, position_id, bd_str(amount), bd_str(rate), bd_str(position_value), now_iso]
        )
        @db.last_insert_row_id
      end

      def total_funding_fees(pair: nil)
        if pair
          v = @db.get_first_value(
            'SELECT COALESCE(SUM(CAST(amount AS REAL)), 0) FROM paper_funding_fees WHERE pair = ?', pair
          )
        else
          v = @db.get_first_value('SELECT COALESCE(SUM(CAST(amount AS REAL)), 0) FROM paper_funding_fees')
        end
        BigDecimal(v.to_s)
      end

      def funding_fees_for_position(position_id)
        @db.execute(
          'SELECT * FROM paper_funding_fees WHERE position_id = ? ORDER BY id', position_id
        ).map { |r| symbolize(r) }
      end

      # --- Position stop/trail ---

      def update_position_stop_price(id, stop_price:)
        @db.execute(
          'UPDATE paper_positions SET stop_price = ?, updated_at = ? WHERE id = ?',
          [bd_str(stop_price), now_iso, id]
        )
      end

      def update_position_trail_price(id, trail_price:)
        @db.execute(
          'UPDATE paper_positions SET trail_price = ?, updated_at = ? WHERE id = ?',
          [bd_str(trail_price), now_iso, id]
        )
      end

      # --- Aggregate queries ---

      def total_fees
        v = @db.get_first_value('SELECT COALESCE(SUM(CAST(fee AS REAL)), 0) FROM paper_fills')
        BigDecimal(v.to_s)
      end

      def total_slippage
        v = @db.get_first_value('SELECT COALESCE(SUM(CAST(slippage AS REAL)), 0) FROM paper_fills')
        BigDecimal(v.to_s)
      end

      def total_realized_pnl
        v = @db.get_first_value("SELECT COALESCE(SUM(CAST(realized_pnl AS REAL)), 0) FROM paper_positions WHERE status = 'closed'")
        BigDecimal(v.to_s)
      end

      def fill_count
        @db.get_first_value('SELECT COUNT(*) FROM paper_fills').to_i
      end

      def order_count(status: nil)
        if status
          @db.get_first_value('SELECT COUNT(*) FROM paper_orders WHERE status = ?', status).to_i
        else
          @db.get_first_value('SELECT COUNT(*) FROM paper_orders').to_i
        end
      end

      private

      def bd_str(value)
        v = value.is_a?(BigDecimal) ? value.to_s('F') : value.to_s
        v
      end

      def now_iso
        Time.now.utc.strftime('%Y-%m-%dT%H:%M:%S.%LZ')
      end

      def symbolize(row)
        return nil unless row

        row.transform_keys(&:to_sym)
      end

      def migrate
        @db.execute_batch(<<~SQL)
          CREATE TABLE IF NOT EXISTS paper_orders (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            pair TEXT NOT NULL,
            side TEXT NOT NULL,
            order_type TEXT NOT NULL,
            price TEXT NOT NULL,
            quantity TEXT NOT NULL,
            status TEXT NOT NULL DEFAULT 'new',
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            limit_price TEXT,
            stop_price TEXT,
            group_id INTEGER,
            group_role TEXT,
            metadata TEXT DEFAULT '{}'
          );

          CREATE TABLE IF NOT EXISTS paper_fills (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            order_id INTEGER NOT NULL,
            price TEXT NOT NULL,
            quantity TEXT NOT NULL,
            fee TEXT NOT NULL DEFAULT '0',
            slippage TEXT NOT NULL DEFAULT '0',
            trigger TEXT NOT NULL DEFAULT 'market_order',
            created_at TEXT NOT NULL,
            FOREIGN KEY (order_id) REFERENCES paper_orders(id)
          );

          CREATE TABLE IF NOT EXISTS paper_positions (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            pair TEXT NOT NULL,
            side TEXT NOT NULL,
            quantity TEXT NOT NULL,
            entry_price TEXT NOT NULL,
            realized_pnl TEXT NOT NULL DEFAULT '0',
            status TEXT NOT NULL DEFAULT 'open',
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
          );

          CREATE TABLE IF NOT EXISTS paper_events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            event_type TEXT NOT NULL,
            payload TEXT NOT NULL DEFAULT '{}',
            created_at TEXT NOT NULL
          );

          CREATE TABLE IF NOT EXISTS paper_account_snapshots (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            equity TEXT NOT NULL,
            realized_pnl TEXT NOT NULL,
            unrealized_pnl TEXT NOT NULL,
            total_fees TEXT NOT NULL DEFAULT '0',
            total_slippage TEXT NOT NULL DEFAULT '0',
            created_at TEXT NOT NULL
          );

          CREATE TABLE IF NOT EXISTS paper_order_groups (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            pair TEXT NOT NULL,
            status TEXT NOT NULL DEFAULT 'active',
            entry_order_id INTEGER,
            sl_order_id INTEGER,
            tp_order_id INTEGER,
            created_at TEXT NOT NULL,
            completed_at TEXT
          );

          CREATE TABLE IF NOT EXISTS paper_funding_fees (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            pair TEXT NOT NULL,
            position_id INTEGER NOT NULL,
            amount TEXT NOT NULL,
            rate TEXT NOT NULL,
            position_value TEXT NOT NULL,
            created_at TEXT NOT NULL,
            FOREIGN KEY (position_id) REFERENCES paper_positions(id)
          );

          CREATE INDEX IF NOT EXISTS idx_paper_orders_pair_status ON paper_orders(pair, status);
          CREATE INDEX IF NOT EXISTS idx_paper_positions_pair_status ON paper_positions(pair, status);
          CREATE INDEX IF NOT EXISTS idx_paper_fills_order_id ON paper_fills(order_id);
          CREATE INDEX IF NOT EXISTS idx_paper_order_groups_pair_status ON paper_order_groups(pair, status);
          CREATE INDEX IF NOT EXISTS idx_paper_funding_fees_position ON paper_funding_fees(position_id);
        SQL

        migrate_legacy_columns
      end

      def migrate_legacy_columns
        add_column_if_missing('paper_orders', 'limit_price', 'TEXT')
        add_column_if_missing('paper_orders', 'stop_price', 'TEXT')
        add_column_if_missing('paper_orders', 'group_id', 'INTEGER')
        add_column_if_missing('paper_orders', 'group_role', 'TEXT')
        add_column_if_missing('paper_orders', 'metadata', "TEXT DEFAULT '{}'")
        add_column_if_missing('paper_fills', 'trigger', "TEXT NOT NULL DEFAULT 'market_order'")
        add_column_if_missing('paper_positions', 'stop_price', 'TEXT')
        add_column_if_missing('paper_positions', 'trail_price', 'TEXT')
      end

      def add_column_if_missing(table, column, sql_type)
        raise ArgumentError, "invalid table #{table}" unless MIGRATE_TABLE_ALLOWLIST.include?(table)
        raise ArgumentError, "invalid column #{column}" unless column.match?(/\A[a-z_][a-z0-9_]*\z/)

        cols = @db.table_info(table).map { |row| row['name'] }
        return if cols.include?(column)

        @db.execute("ALTER TABLE #{table} ADD COLUMN #{column} #{sql_type}")
      end
    end
  end
end
