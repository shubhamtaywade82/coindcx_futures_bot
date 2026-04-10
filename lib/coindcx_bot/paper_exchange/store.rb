# frozen_string_literal: true

require 'sqlite3'
require 'fileutils'
require 'json'
require 'bigdecimal'

module CoindcxBot
  module PaperExchange
    # SQLite persistence for the paper exchange (separate from legacy PaperStore).
    class Store
      def initialize(path)
        FileUtils.mkdir_p(File.dirname(path))
        @db = SQLite3::Database.new(path)
        @db.results_as_hash = true
        migrate
      end

      attr_reader :db

      def close
        @db.close
      end

      def migrate
        @db.execute_batch(<<~SQL)
          CREATE TABLE IF NOT EXISTS pe_users (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            created_at TEXT NOT NULL
          );

          CREATE TABLE IF NOT EXISTS pe_api_keys (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            user_id INTEGER NOT NULL,
            api_key TEXT NOT NULL UNIQUE,
            api_secret TEXT NOT NULL,
            FOREIGN KEY (user_id) REFERENCES pe_users(id)
          );

          CREATE TABLE IF NOT EXISTS pe_ledger_accounts (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            user_id INTEGER NOT NULL,
            code TEXT NOT NULL,
            UNIQUE(user_id, code)
          );

          CREATE TABLE IF NOT EXISTS pe_ledger_batches (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            user_id INTEGER NOT NULL,
            external_ref TEXT,
            memo TEXT,
            created_at TEXT NOT NULL,
            UNIQUE(user_id, external_ref)
          );

          CREATE TABLE IF NOT EXISTS pe_ledger_lines (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            batch_id INTEGER NOT NULL,
            account_id INTEGER NOT NULL,
            amount_usdt TEXT NOT NULL,
            FOREIGN KEY (batch_id) REFERENCES pe_ledger_batches(id),
            FOREIGN KEY (account_id) REFERENCES pe_ledger_accounts(id)
          );

          CREATE TABLE IF NOT EXISTS pe_mark_prices (
            pair TEXT PRIMARY KEY,
            ltp TEXT NOT NULL,
            high TEXT,
            low TEXT,
            updated_at TEXT NOT NULL
          );

          CREATE TABLE IF NOT EXISTS pe_market_rules (
            pair TEXT PRIMARY KEY,
            min_quantity TEXT NOT NULL DEFAULT '0',
            max_quantity TEXT,
            price_precision INTEGER DEFAULT 8,
            quantity_precision INTEGER DEFAULT 8,
            allowed_order_types TEXT NOT NULL DEFAULT '["market_order","limit_order"]',
            market_status TEXT NOT NULL DEFAULT 'active'
          );

          CREATE TABLE IF NOT EXISTS pe_orders (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            user_id INTEGER NOT NULL,
            client_order_id TEXT NOT NULL,
            pair TEXT NOT NULL,
            side TEXT NOT NULL,
            order_type TEXT NOT NULL,
            order_stage TEXT NOT NULL DEFAULT 'standard',
            status TEXT NOT NULL,
            price TEXT,
            limit_price TEXT,
            stop_price TEXT,
            total_quantity TEXT NOT NULL,
            remaining_quantity TEXT NOT NULL,
            avg_fill_price TEXT,
            leverage INTEGER NOT NULL DEFAULT 1,
            margin_mode TEXT NOT NULL DEFAULT 'cross',
            fee_paid TEXT NOT NULL DEFAULT '0',
            reserved_margin TEXT NOT NULL DEFAULT '0',
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            UNIQUE(user_id, client_order_id)
          );

          CREATE INDEX IF NOT EXISTS idx_pe_orders_user_pair_status
            ON pe_orders(user_id, pair, status);

          CREATE TABLE IF NOT EXISTS pe_fills (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            user_id INTEGER NOT NULL,
            order_id INTEGER NOT NULL,
            price TEXT NOT NULL,
            quantity TEXT NOT NULL,
            fee TEXT NOT NULL,
            trigger TEXT NOT NULL DEFAULT 'fill',
            created_at TEXT NOT NULL,
            FOREIGN KEY (order_id) REFERENCES pe_orders(id)
          );

          CREATE TABLE IF NOT EXISTS pe_positions (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            user_id INTEGER NOT NULL,
            pair TEXT NOT NULL,
            side TEXT NOT NULL,
            quantity TEXT NOT NULL,
            avg_entry_price TEXT NOT NULL,
            leverage INTEGER NOT NULL,
            margin_mode TEXT NOT NULL DEFAULT 'cross',
            isolated_margin TEXT NOT NULL DEFAULT '0',
            maintenance_margin TEXT NOT NULL DEFAULT '0',
            liquidation_price TEXT,
            realized_pnl_session TEXT NOT NULL DEFAULT '0',
            status TEXT NOT NULL DEFAULT 'open',
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
          );

          CREATE UNIQUE INDEX IF NOT EXISTS idx_pe_positions_one_open_per_pair
            ON pe_positions(user_id, pair) WHERE status = 'open';

          CREATE TABLE IF NOT EXISTS pe_position_margin_events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            position_id INTEGER NOT NULL,
            kind TEXT NOT NULL,
            amount TEXT NOT NULL,
            created_at TEXT NOT NULL,
            FOREIGN KEY (position_id) REFERENCES pe_positions(id)
          );

          CREATE TABLE IF NOT EXISTS pe_internal_events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            event_type TEXT NOT NULL,
            payload TEXT NOT NULL,
            created_at TEXT NOT NULL
          );

          CREATE TABLE IF NOT EXISTS pe_simulation_sessions (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            user_id INTEGER NOT NULL,
            fill_mode TEXT NOT NULL DEFAULT 'candle',
            created_at TEXT NOT NULL
          );

          CREATE TABLE IF NOT EXISTS pe_market_snapshots (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            pair TEXT NOT NULL,
            payload TEXT NOT NULL,
            created_at TEXT NOT NULL
          );
        SQL
      end

      def now_iso
        Time.now.utc.iso8601
      end

      def symbolize(row)
        return nil unless row

        row.transform_keys(&:to_sym)
      end
    end
  end
end
