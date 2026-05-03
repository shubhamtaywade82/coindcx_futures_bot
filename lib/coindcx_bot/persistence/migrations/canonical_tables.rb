# frozen_string_literal: true

module CoindcxBot
  module Persistence
    module Migrations
      # Canonical schema covering markets/candles/signals/trades/risk_events/
      # order_book_snapshots + idempotency dedup. Forward-only: every column
      # must accept NULL or have a default so existing rows survive future
      # ALTERs without manual backfill.
      #
      # Decimal money values are stored as TEXT (BigDecimal serialized
      # losslessly via `.to_s`). Timestamps are millisecond epoch INTEGER
      # to match the existing journal.rb convention.
      class CanonicalTables
        VERSION = 1
        NAME = 'canonical_tables'

        def version = VERSION
        def name = NAME

        def up(db)
          db.execute_batch(SQL)
        end

        SQL = <<~SQL
          -- B1.MarketCatalog
          CREATE TABLE IF NOT EXISTS markets (
            pair TEXT PRIMARY KEY,
            symbol TEXT,
            ecode TEXT,
            base TEXT,
            quote TEXT,
            price_step TEXT,
            qty_step TEXT,
            min_notional TEXT,
            max_leverage INTEGER,
            meta TEXT,
            updated_at INTEGER NOT NULL
          );

          -- B7. Multi-interval candle cache for backtest + cold start
          CREATE TABLE IF NOT EXISTS candles (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            pair TEXT NOT NULL,
            interval TEXT NOT NULL,
            ts INTEGER NOT NULL,
            o TEXT NOT NULL,
            h TEXT NOT NULL,
            l TEXT NOT NULL,
            c TEXT NOT NULL,
            v TEXT NOT NULL,
            UNIQUE(pair, interval, ts)
          );
          CREATE INDEX IF NOT EXISTS idx_candles_pair_interval_ts
            ON candles(pair, interval, ts DESC);

          -- B7/B4. Signal log; payload holds components, p_hit, expected_r
          CREATE TABLE IF NOT EXISTS signals (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            signal_id TEXT NOT NULL UNIQUE,
            pair TEXT NOT NULL,
            side TEXT NOT NULL,
            score REAL,
            regime TEXT,
            entry_price TEXT,
            stop_loss TEXT,
            take_profit TEXT,
            payload TEXT NOT NULL,
            fired_at INTEGER NOT NULL,
            state TEXT NOT NULL DEFAULT 'fired'
          );
          CREATE INDEX IF NOT EXISTS idx_signals_pair_fired ON signals(pair, fired_at DESC);
          CREATE INDEX IF NOT EXISTS idx_signals_state ON signals(state);

          -- B7. Closed trade ledger (distinct from open positions tracked elsewhere)
          CREATE TABLE IF NOT EXISTS trades (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            trade_id TEXT NOT NULL UNIQUE,
            signal_id TEXT,
            position_id INTEGER,
            pair TEXT NOT NULL,
            side TEXT NOT NULL,
            entry_price TEXT,
            exit_price TEXT,
            quantity TEXT,
            gross_pnl TEXT,
            fees TEXT,
            net_pnl TEXT,
            exit_reason TEXT,
            entry_at INTEGER,
            exit_at INTEGER
          );
          CREATE INDEX IF NOT EXISTS idx_trades_pair_exit ON trades(pair, exit_at DESC);
          CREATE INDEX IF NOT EXISTS idx_trades_signal_id ON trades(signal_id);

          -- B5/B9. Risk events: time_stop_kill, ws_gap, exposure_block, etc.
          CREATE TABLE IF NOT EXISTS risk_events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            kind TEXT NOT NULL,
            severity TEXT NOT NULL DEFAULT 'info',
            pair TEXT,
            payload TEXT NOT NULL,
            ts INTEGER NOT NULL
          );
          CREATE INDEX IF NOT EXISTS idx_risk_events_kind_ts ON risk_events(kind, ts DESC);

          -- B7/B8. Compressed orderbook snapshots for replay; payload is
          -- JSON {bids: [[price, qty], ...], asks: [...]} serialized.
          CREATE TABLE IF NOT EXISTS order_book_snapshots (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            pair TEXT NOT NULL,
            ts INTEGER NOT NULL,
            vs INTEGER,
            payload TEXT NOT NULL
          );
          CREATE INDEX IF NOT EXISTS idx_order_book_snapshots_pair_ts
            ON order_book_snapshots(pair, ts DESC);

          -- B6. Idempotency dedup. Composite PK ensures
          -- (client_order_id, event_id, kind) is unique exactly once.
          CREATE TABLE IF NOT EXISTS client_event_dedup (
            client_order_id TEXT NOT NULL,
            event_id TEXT NOT NULL,
            kind TEXT NOT NULL,
            recorded_at INTEGER NOT NULL,
            PRIMARY KEY (client_order_id, event_id, kind)
          );
        SQL
      end
    end
  end
end
