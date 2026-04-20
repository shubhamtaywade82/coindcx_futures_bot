# frozen_string_literal: true

require 'sqlite3'
require 'json'
require 'fileutils'
require 'monitor'

module CoindcxBot
  module Persistence
    class Journal
      def initialize(path, event_sink: nil)
        @path = path
        @event_sink = event_sink
        FileUtils.mkdir_p(File.dirname(path))
        @db = SQLite3::Database.new(path)
        @db.results_as_hash = true
        @db_mutex = Monitor.new
        migrate
      end

      def close
        @db.close
      end

      def meta_get(key)
        db_sync { @db.get_first_value('SELECT value FROM meta WHERE key = ?', key.to_s) }
      end

      def meta_set(key, value)
        db_sync do
          @db.execute(
            'INSERT INTO meta(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value',
            [key.to_s, value.to_s]
          )
        end
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
      rescue ArgumentError
        BigDecimal('0')
      end

      def add_daily_pnl_inr(delta)
        db_sync do
          key = "pnl_day:#{daily_key}"
          cur = @db.get_first_value('SELECT value FROM meta WHERE key = ?', key)
          current = begin
            BigDecimal(blank?(cur) ? '0' : cur)
          rescue ArgumentError
            BigDecimal('0')
          end
          @db.execute(
            'INSERT INTO meta(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value',
            [key, (current + delta).to_s('F')]
          )
        end
      end

      # Keeps `pnl_current_day` in meta aligned with UTC calendar days.
      # Realized PnL for "today" already uses `pnl_day:#{daily_key}`; a new UTC day reads a new key (starts at 0).
      # Call this from the engine loop so the marker initializes on first run and updates after rollovers.
      def reset_daily_pnl_if_new_day!
        db_sync do
          last = @db.get_first_value('SELECT value FROM meta WHERE key = ?', 'pnl_current_day')
          today = daily_key
          return if last == today

          @db.execute(
            'INSERT INTO meta(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value',
            ['pnl_current_day', today]
          )
        end
      end

      def open_positions
        db_sync do
          @db.execute('SELECT * FROM positions WHERE state = ?', 'open').map { |row| symbolize_row(row) }
        end
      end

      def insert_position(pair:, side:, entry_price:, quantity:, stop_price:, trail_price: nil,
                          initial_stop_price: nil, smc_setup_id: nil, entry_lane: nil)
        db_sync do
          now = Time.now.to_i
          initial = (initial_stop_price || stop_price)&.to_s('F')
          sid = smc_setup_id&.to_s
          sid = nil if sid&.strip&.empty?
          lane = entry_lane&.to_s&.strip
          lane = nil if lane&.empty?
          @db.execute(
            <<~SQL,
              INSERT INTO positions(pair, side, entry_price, quantity, stop_price, trail_price, initial_stop_price, partial_done, opened_at, state, smc_setup_id, entry_lane)
              VALUES(?, ?, ?, ?, ?, ?, ?, 0, ?, 'open', ?, ?)
            SQL
            [pair, side.to_s, entry_price.to_s('F'), quantity.to_s('F'),
             stop_price&.to_s('F'), trail_price&.to_s('F'), initial, now, sid, lane]
          )
          @db.last_insert_row_id
        end
      end

      def update_position_trail(id, trail_price)
        db_sync { @db.execute('UPDATE positions SET trail_price = ? WHERE id = ?', [trail_price.to_s('F'), id]) }
      end

      def update_position_stop(id, stop_price)
        db_sync { @db.execute('UPDATE positions SET stop_price = ? WHERE id = ?', [stop_price.to_s('F'), id]) }
      end

      def update_position_entry_price(id, fill_price)
        db_sync do
          @db.execute(
            'UPDATE positions SET entry_price = ? WHERE id = ?',
            [BigDecimal(fill_price.to_s).to_s('F'), id]
          )
        end
      end

      def mark_partial(id)
        db_sync { @db.execute('UPDATE positions SET partial_done = 1 WHERE id = ?', id) }
      end

      # Monotonic max unrealized USDT (MFE) for HWM giveback; persists peak_unrealized_usdt.
      def bump_peak_unrealized_usdt(id, current_usdt)
        return nil if id.nil?

        db_sync do
          cur = BigDecimal(current_usdt.to_s)
          row = @db.get_first_row(
            'SELECT peak_unrealized_usdt FROM positions WHERE id = ? AND state = ?',
            [id, 'open']
          )
          return nil unless row

          raw = row['peak_unrealized_usdt']
          prev = blank?(raw) ? nil : BigDecimal(raw.to_s)
          new_peak = prev.nil? ? cur : [prev, cur].max
          return new_peak if prev == new_peak

          @db.execute(
            'UPDATE positions SET peak_unrealized_usdt = ? WHERE id = ? AND state = ?',
            [new_peak.to_s('F'), id, 'open']
          )
          new_peak
        end
      end

      def close_position(id)
        return if id.nil?

        db_sync { @db.execute("UPDATE positions SET state = 'closed' WHERE id = ?", id) }
      end

      def bar_cursor(pair, resolution)
        meta_get("bar:#{pair}:#{resolution}")
      end

      def set_bar_cursor(pair, resolution, iso8601)
        meta_set("bar:#{pair}:#{resolution}", iso8601)
      end

      def log_event(type, payload = {})
        db_sync do
          @db.execute(
            'INSERT INTO event_log(ts, type, payload) VALUES(?, ?, ?)',
            [Time.now.to_i, type.to_s, JSON.generate(payload)]
          )
        end
        notify_event_sink(type, payload)
      end

      # Wraps a block in an exclusive SQLite transaction so multi-step writes are atomic.
      # On exception the transaction is rolled back and the error re-raised.
      # Uses a reentrant Monitor so callers within the block can safely call other Journal methods.
      def within_transaction(&block)
        db_sync { @db.transaction(:exclusive, &block) }
      end

      def recent_events(limit = 50)
        db_sync { @db.execute('SELECT ts, type, payload FROM event_log ORDER BY id DESC LIMIT ?', limit) }
      end

      # Sum of `pnl_usdt` from coordinator `paper_realized` events (USDT). Used when the broker
      # has no in-process paper store (e.g. gateway paper) but the journal still books closes.
      def sum_paper_realized_pnl_usdt
        rows = db_sync { @db.execute('SELECT payload FROM event_log WHERE type = ?', ['paper_realized']) }
        rows.sum(BigDecimal('0')) do |row|
          raw = row['payload'] || row[:payload]
          h = JSON.parse(raw.to_s, symbolize_names: true)
          BigDecimal((h[:pnl_usdt] || h['pnl_usdt'] || '0').to_s)
        rescue JSON::ParserError, ArgumentError, TypeError
          BigDecimal('0')
        end
      end

      TERMINAL_SMC_SETUP_STATES = %w[completed invalidated].freeze

      def smc_setup_load_active
        db_sync do
          placeholders = TERMINAL_SMC_SETUP_STATES.map { '?' }.join(', ')
          sql = "SELECT setup_id, pair, state, payload, eval_state FROM smc_trade_setups WHERE state NOT IN (#{placeholders})"
          @db.execute(sql, TERMINAL_SMC_SETUP_STATES).map { |row| symbolize_row(row) }
        end
      end

      def smc_setup_count_for_pair(pair)
        db_sync do
          placeholders = TERMINAL_SMC_SETUP_STATES.map { '?' }.join(', ')
          sql = "SELECT COUNT(*) AS c FROM smc_trade_setups WHERE pair = ? AND state NOT IN (#{placeholders})"
          row = @db.get_first_row(sql, [pair.to_s, *TERMINAL_SMC_SETUP_STATES])
          row ? row['c'].to_i : 0
        end
      end

      # Oldest non-terminal rows first (`created_at`, then `setup_id`). Skips setups linked to an
      # open position so live risk state is never dropped to make room for a new planner row.
      def smc_setup_invalidate_oldest_active_for_pair!(pair, slots_needed:)
        need = slots_needed.to_i
        return 0 if need <= 0

        freed_ids = []
        db_sync do
          placeholders = TERMINAL_SMC_SETUP_STATES.map { '?' }.join(', ')
          sql = <<~SQL
            SELECT setup_id FROM smc_trade_setups
            WHERE pair = ? AND state NOT IN (#{placeholders})
            ORDER BY created_at ASC, setup_id ASC
          SQL
          rows = @db.execute(sql, [pair.to_s, *TERMINAL_SMC_SETUP_STATES])
          rows.each do |row|
            break if freed_ids.size >= need

            sid = (row['setup_id'] || row[:setup_id]).to_s
            next if sid.empty?

            has_open = @db.get_first_row(
              'SELECT 1 AS o FROM positions WHERE state = ? AND smc_setup_id = ? LIMIT 1',
              ['open', sid]
            )
            next if has_open

            now = Time.now.to_i
            @db.execute(
              'UPDATE smc_trade_setups SET state = ?, updated_at = ? WHERE setup_id = ?',
              ['invalidated', now, sid]
            )
            @db.execute(
              'INSERT INTO event_log(ts, type, payload) VALUES(?, ?, ?)',
              [now, 'smc_setup_invalidated',
               JSON.generate(reason: 'capacity_eviction', pair: pair.to_s, setup_id: sid)]
            )
            freed_ids << sid
          end
        end
        freed_ids.each do |sid|
          notify_event_sink('smc_setup_invalidated', reason: 'capacity_eviction', pair: pair.to_s, setup_id: sid)
        end
        freed_ids.size
      end

      def smc_setup_insert_or_update(setup_id:, pair:, state:, payload:, eval_state: {})
        db_sync do
          now = Time.now.to_i
          payload_s = payload.is_a?(String) ? payload : JSON.generate(payload)
          ev = eval_state.is_a?(String) ? eval_state : JSON.generate(eval_state || {})
          existing = @db.get_first_row('SELECT id FROM smc_trade_setups WHERE setup_id = ?', setup_id.to_s)
          if existing
            @db.execute(
              'UPDATE smc_trade_setups SET pair = ?, state = ?, payload = ?, eval_state = ?, updated_at = ? WHERE setup_id = ?',
              [pair.to_s, state.to_s, payload_s, ev, now, setup_id.to_s]
            )
          else
            @db.execute(
              <<~SQL,
                INSERT INTO smc_trade_setups(setup_id, pair, state, payload, eval_state, created_at, updated_at)
                VALUES(?, ?, ?, ?, ?, ?, ?)
              SQL
              [setup_id.to_s, pair.to_s, state.to_s, payload_s, ev, now, now]
            )
          end
        end
      end

      def smc_setup_update_state_and_eval(setup_id:, state:, eval_state: nil)
        db_sync do
          now = Time.now.to_i
          if eval_state.nil?
            @db.execute(
              'UPDATE smc_trade_setups SET state = ?, updated_at = ? WHERE setup_id = ?',
              [state.to_s, now, setup_id.to_s]
            )
          else
            ev = eval_state.is_a?(String) ? eval_state : JSON.generate(eval_state)
            @db.execute(
              'UPDATE smc_trade_setups SET state = ?, eval_state = ?, updated_at = ? WHERE setup_id = ?',
              [state.to_s, ev, now, setup_id.to_s]
            )
          end
        end
      end

      def smc_setup_fetch_payload(setup_id)
        row = db_sync { @db.get_first_row('SELECT payload FROM smc_trade_setups WHERE setup_id = ?', setup_id.to_s) }
        return nil unless row

        JSON.parse(row['payload'].to_s, symbolize_names: true)
      rescue JSON::ParserError
        nil
      end

      def smc_setup_exists?(setup_id)
        db_sync do
          !@db.get_first_row('SELECT 1 AS o FROM smc_trade_setups WHERE setup_id = ? LIMIT 1', setup_id.to_s).nil?
        end
      end

      def smc_setup_get_row(setup_id)
        row = db_sync do
          @db.get_first_row(
            'SELECT setup_id, pair, state, payload, eval_state FROM smc_trade_setups WHERE setup_id = ?',
            setup_id.to_s
          )
        end
        row ? symbolize_row(row) : nil
      end

      def open_position_with_smc_setup?(setup_id)
        sid = setup_id.to_s
        db_sync do
          row = @db.get_first_row(
            'SELECT 1 AS o FROM positions WHERE state = ? AND smc_setup_id = ? LIMIT 1',
            ['open', sid]
          )
          !row.nil?
        end
      end

      def smc_setup_count_all
        db_sync do
          row = @db.get_first_row('SELECT COUNT(*) AS c FROM smc_trade_setups')
          row ? row['c'].to_i : 0
        end
      end

      def smc_setup_list_recent(limit = 15)
        db_sync do
          lim = [[limit.to_i, 1].max, 100].min
          @db.execute(
            'SELECT setup_id, pair, state, updated_at FROM smc_trade_setups ORDER BY updated_at DESC LIMIT ?',
            lim
          ).map { |row| symbolize_row(row) }
        end
      end

      private

      def db_sync(&block)
        @db_mutex.synchronize(&block)
      end

      def notify_event_sink(type, payload)
        s = @event_sink
        return unless s&.respond_to?(:deliver)

        s.deliver(type, payload)
      rescue StandardError
        nil
      end

      def blank?(v)
        v.nil? || v.to_s.strip.empty?
      end

      def symbolize_row(row)
        row.transform_keys(&:to_sym)
      end

      def migrate
        @db.execute('PRAGMA journal_mode=WAL')
        @db.execute('PRAGMA busy_timeout=5000')
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
            initial_stop_price TEXT,
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
          CREATE INDEX IF NOT EXISTS idx_event_log_type ON event_log(type);
        SQL
        migrate_positions_columns
        migrate_smc_trade_setups_table
      end

      def migrate_positions_columns
        cols = @db.table_info('positions').map { |r| r['name'] }
        unless cols.include?('initial_stop_price')
          @db.execute('ALTER TABLE positions ADD COLUMN initial_stop_price TEXT')
          cols = @db.table_info('positions').map { |r| r['name'] }
        end
        unless cols.include?('peak_unrealized_usdt')
          @db.execute('ALTER TABLE positions ADD COLUMN peak_unrealized_usdt TEXT')
          cols = @db.table_info('positions').map { |r| r['name'] }
        end
        unless cols.include?('smc_setup_id')
          @db.execute('ALTER TABLE positions ADD COLUMN smc_setup_id TEXT')
          cols = @db.table_info('positions').map { |r| r['name'] }
        end
        return if cols.include?('entry_lane')

        @db.execute('ALTER TABLE positions ADD COLUMN entry_lane TEXT')
      end

      def migrate_smc_trade_setups_table
        @db.execute_batch(<<~SQL)
          CREATE TABLE IF NOT EXISTS smc_trade_setups (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            setup_id TEXT NOT NULL UNIQUE,
            pair TEXT NOT NULL,
            state TEXT NOT NULL,
            payload TEXT NOT NULL,
            eval_state TEXT NOT NULL DEFAULT '{}',
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL
          );
          CREATE INDEX IF NOT EXISTS idx_smc_trade_setups_pair ON smc_trade_setups(pair);
        SQL
      end
    end
  end
end
