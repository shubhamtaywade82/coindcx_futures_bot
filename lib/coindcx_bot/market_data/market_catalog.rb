# frozen_string_literal: true

require 'json'
require 'sqlite3'

module CoindcxBot
  module MarketData
    # Persists CoinDCX `/exchange/v1/markets_details` payloads into the
    # local `markets` table and exposes typed lookups for the rest of the
    # bot (precision, min notional, leverage cap, symbol/pair mapping).
    #
    # The CoinDCX response schema is loosely typed — fields are stored
    # raw in `meta` (JSON) so downstream callers can pull anything we
    # don't promote to a typed column.
    class MarketCatalog
      DEFAULT_TTL_SECONDS = 24 * 60 * 60 # one day

      def initialize(db_path:, client:, logger: nil, clock: -> { Time.now })
        @db_path = db_path
        @client = client
        @logger = logger
        @clock = clock
      end

      def refresh!
        raw = fetch_remote
        rows = raw.filter_map { |r| normalize(r) }
        upsert(rows)
        log(:info, 'market_catalog_refreshed', count: rows.size)
        rows.size
      end

      def lookup(pair:)
        with_db do |db|
          row = db.execute('SELECT * FROM markets WHERE pair = ?', [pair]).first
          row && row_to_hash(db, row)
        end
      end

      def all
        with_db do |db|
          db.execute('SELECT * FROM markets ORDER BY pair').map { |r| row_to_hash(db, r) }
        end
      end

      def stale?(ttl_seconds: DEFAULT_TTL_SECONDS)
        ts = with_db { |db| db.execute('SELECT MIN(updated_at) FROM markets').flatten.first }
        return true if ts.nil?

        now_ms = (@clock.call.to_f * 1000).to_i
        (now_ms - ts.to_i) > (ttl_seconds * 1000)
      end

      private

      def fetch_remote
        result = @client.public.market_data.list_market_details
        Array(result).map { |m| m.respond_to?(:to_h) ? m.to_h : m }
      end

      def normalize(attrs)
        attrs = symbolize_keys(attrs)
        pair = (attrs[:pair] || attrs[:coindcx_name]).to_s
        return nil if pair.empty?

        {
          pair: pair,
          symbol: attrs[:symbol].to_s,
          ecode: attrs[:ecode].to_s,
          base: attrs[:base_currency_short_name].to_s,
          quote: attrs[:target_currency_short_name].to_s,
          price_step: numeric_or_nil(attrs[:step]),
          qty_step: numeric_or_nil(attrs[:min_quantity]),
          min_notional: numeric_or_nil(attrs[:min_notional]),
          max_leverage: integer_or_nil(attrs[:max_leverage]),
          meta: attrs.to_json,
        }
      end

      def upsert(rows)
        return if rows.empty?

        now_ms = (@clock.call.to_f * 1000).to_i
        with_db do |db|
          db.transaction do
            rows.each do |r|
              db.execute(
                <<~SQL,
                  INSERT INTO markets(pair, symbol, ecode, base, quote, price_step, qty_step, min_notional, max_leverage, meta, updated_at)
                  VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                  ON CONFLICT(pair) DO UPDATE SET
                    symbol = excluded.symbol,
                    ecode = excluded.ecode,
                    base = excluded.base,
                    quote = excluded.quote,
                    price_step = excluded.price_step,
                    qty_step = excluded.qty_step,
                    min_notional = excluded.min_notional,
                    max_leverage = excluded.max_leverage,
                    meta = excluded.meta,
                    updated_at = excluded.updated_at
                SQL
                [r[:pair], r[:symbol], r[:ecode], r[:base], r[:quote],
                 r[:price_step], r[:qty_step], r[:min_notional], r[:max_leverage],
                 r[:meta], now_ms,]
              )
            end
          end
        end
      end

      def row_to_hash(db, row)
        cols = db.execute('PRAGMA table_info(markets)').map { |c| c[1] }
        cols.zip(row).to_h.transform_keys(&:to_sym)
      end

      def with_db
        db = SQLite3::Database.new(@db_path)
        db.execute('PRAGMA busy_timeout=5000')
        yield db
      ensure
        db&.close
      end

      def symbolize_keys(hash)
        hash.each_with_object({}) { |(k, v), memo| memo[k.to_sym] = v }
      end

      def numeric_or_nil(value)
        return nil if value.nil? || value.to_s.strip.empty?

        Float(value).to_s
      rescue ArgumentError, TypeError
        nil
      end

      def integer_or_nil(value)
        return nil if value.nil? || value.to_s.strip.empty?

        Integer(value)
      rescue ArgumentError, TypeError
        nil
      end

      def log(level, event, payload)
        return unless @logger

        @logger.public_send(level, event, payload)
      end
    end
  end
end
