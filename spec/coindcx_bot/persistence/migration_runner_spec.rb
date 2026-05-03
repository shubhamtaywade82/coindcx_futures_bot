# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'sqlite3'
require 'coindcx_bot/persistence/migrations'

RSpec.describe CoindcxBot::Persistence::MigrationRunner do
  let(:tmp_dir) { Dir.mktmpdir('migration_runner_spec') }
  let(:db_path) { File.join(tmp_dir, 'test.sqlite3') }

  after { FileUtils.remove_entry(tmp_dir) }

  describe '#run!' do
    it 'creates schema_migrations and the canonical tables on first run' do
      runner = CoindcxBot::Persistence::Migrations.runner_for(db_path: db_path)
      runner.run!

      db = SQLite3::Database.new(db_path)
      tables = db.execute("SELECT name FROM sqlite_master WHERE type='table'").flatten

      expect(tables).to include(
        'schema_migrations',
        'markets',
        'candles',
        'signals',
        'trades',
        'risk_events',
        'order_book_snapshots',
        'client_event_dedup'
      )

      versions = db.execute('SELECT version FROM schema_migrations ORDER BY version').flatten
      expect(versions).to eq([1])
    ensure
      db&.close
    end

    it 'is idempotent across runs' do
      2.times do
        CoindcxBot::Persistence::Migrations.runner_for(db_path: db_path).run!
      end

      db = SQLite3::Database.new(db_path)
      versions = db.execute('SELECT version FROM schema_migrations').flatten
      expect(versions).to eq([1])
    ensure
      db&.close
    end

    it 'enforces unique (pair, interval, ts) on candles' do
      CoindcxBot::Persistence::Migrations.runner_for(db_path: db_path).run!

      db = SQLite3::Database.new(db_path)
      now = (Time.now.to_f * 1000).to_i
      db.execute(
        "INSERT INTO candles(pair, interval, ts, o, h, l, c, v) VALUES('BTC_USDT','5m',?,?,?,?,?,?)",
        [now, '1', '2', '0.5', '1.5', '100']
      )

      expect do
        db.execute(
          "INSERT INTO candles(pair, interval, ts, o, h, l, c, v) VALUES('BTC_USDT','5m',?,?,?,?,?,?)",
          [now, '1', '2', '0.5', '1.5', '100']
        )
      end.to raise_error(SQLite3::ConstraintException)
    ensure
      db&.close
    end

    it 'enforces composite PK on client_event_dedup' do
      CoindcxBot::Persistence::Migrations.runner_for(db_path: db_path).run!

      db = SQLite3::Database.new(db_path)
      ts = (Time.now.to_f * 1000).to_i
      db.execute(
        'INSERT INTO client_event_dedup(client_order_id, event_id, kind, recorded_at) VALUES(?, ?, ?, ?)',
        ['cli-1', 'evt-1', 'fill', ts]
      )

      expect do
        db.execute(
          'INSERT INTO client_event_dedup(client_order_id, event_id, kind, recorded_at) VALUES(?, ?, ?, ?)',
          ['cli-1', 'evt-1', 'fill', ts]
        )
      end.to raise_error(SQLite3::ConstraintException)
    ensure
      db&.close
    end
  end

  describe '#applied_versions' do
    it 'returns empty before run!' do
      runner = CoindcxBot::Persistence::Migrations.runner_for(db_path: db_path)
      expect(runner.applied_versions).to eq([])
    end

    it 'returns sorted versions after run!' do
      runner = CoindcxBot::Persistence::Migrations.runner_for(db_path: db_path)
      runner.run!
      expect(runner.applied_versions).to eq([1])
    end
  end
end
