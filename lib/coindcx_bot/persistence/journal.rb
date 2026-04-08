# frozen_string_literal: true

require 'sqlite3'
require 'json'
require 'fileutils'

module CoindcxBot
  module Persistence
    class Journal
      def initialize(path)
        @path = path
        FileUtils.mkdir_p(File.dirname(path))
        @db = SQLite3::Database.new(path)
        @db.results_as_hash = true
        migrate
      end

      def close
        @db.close
      end

      def meta_get(key)
        row = @db.get_first_value('SELECT value FROM meta WHERE key = ?', key.to_s)
        row
      end

      def meta_set(key, value)
        @db.execute(
          'INSERT INTO meta(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value',
          [key.to_s, value.to_s]
        )
      end

      def kill_switch?
        meta_get('kill_switch') == '1'
      end

      def set_kill_switch(on)
        meta_set('kill_switch', on ? '1' : '0')
      end

      def paused?
        meta_get('paused') == '1'
      end

      def set_paused(on)
        meta_set('paused', on ? '1' : '0')
      end

      def daily_key
        Time.now.utc.strftime('%Y-%m-%d')
      end

      def daily_pnl_inr
        v = meta_get("pnl_day:#{daily_key}")
        BigDecimal(blank?(v) ? '0' : v)
      end

      def add_daily_pnl_inr(delta)
        key = "pnl_day:#{daily_key}"
        cur = meta_get(key)
        current = BigDecimal(blank?(cur) ? '0' : cur)
        meta_set(key, (current + delta).to_s('F'))
      end

      # Keeps `pnl_current_day` in meta aligned with UTC calendar days.
      # Realized PnL for "today" already uses `pnl_day:#{daily_key}`; a new UTC day reads a new key (starts at 0).
      # Call this from the engine loop so the marker initializes on first run and updates after rollovers.
      def reset_daily_pnl_if_new_day!
        last = meta_get('pnl_current_day')
        today = daily_key
        return if last == today

        meta_set('pnl_current_day', today)
      end

      def open_positions
        @db.execute('SELECT * FROM positions WHERE state = ?', 'open').map { |row| symbolize_row(row) }
      end

      def insert_position(pair:, side:, entry_price:, quantity:, stop_price:, trail_price: nil)
        now = Time.now.to_i
        @db.execute(
          <<~SQL,
            INSERT INTO positions(pair, side, entry_price, quantity, stop_price, trail_price, partial_done, opened_at, state)
            VALUES(?, ?, ?, ?, ?, ?, 0, ?, 'open')
          SQL
          [pair, side.to_s, entry_price.to_s('F'), quantity.to_s('F'),
           stop_price&.to_s('F'), trail_price&.to_s('F'), now]
        )
        @db.last_insert_row_id
      end

      def update_position_trail(id, trail_price)
        @db.execute('UPDATE positions SET trail_price = ? WHERE id = ?', [trail_price.to_s('F'), id])
      end

      def update_position_stop(id, stop_price)
        @db.execute('UPDATE positions SET stop_price = ? WHERE id = ?', [stop_price.to_s('F'), id])
      end

      def mark_partial(id)
        @db.execute('UPDATE positions SET partial_done = 1 WHERE id = ?', id)
      end

      def close_position(id)
        @db.execute("UPDATE positions SET state = 'closed' WHERE id = ?", id)
      end

      def bar_cursor(pair, resolution)
        meta_get("bar:#{pair}:#{resolution}")
      end

      def set_bar_cursor(pair, resolution, iso8601)
        meta_set("bar:#{pair}:#{resolution}", iso8601)
      end

      def log_event(type, payload = {})
        @db.execute(
          'INSERT INTO event_log(ts, type, payload) VALUES(?, ?, ?)',
          [Time.now.to_i, type.to_s, JSON.generate(payload)]
        )
      end

      def recent_events(limit = 50)
        @db.execute('SELECT ts, type, payload FROM event_log ORDER BY id DESC LIMIT ?', limit)
      end

      private

      def blank?(v)
        v.nil? || v.to_s.strip.empty?
      end

      def symbolize_row(row)
        row.transform_keys(&:to_sym)
      end

      def migrate
        @db.execute_batch(<<~SQL)
          CREATE TABLE IF NOT EXISTS meta (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
          );
          CREATE TABLE IF NOT EXISTS positions (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            pair TEXT NOT NULL,
            side TEXT NOT NULL,
            entry_price TEXT NOT NULL,
            quantity TEXT NOT NULL,
            stop_price TEXT,
            trail_price TEXT,
            partial_done INTEGER DEFAULT 0,
            opened_at INTEGER NOT NULL,
            state TEXT NOT NULL
          );
          CREATE TABLE IF NOT EXISTS event_log (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            ts INTEGER NOT NULL,
            type TEXT NOT NULL,
            payload TEXT NOT NULL
          );
        SQL
      end
    end
  end
end
