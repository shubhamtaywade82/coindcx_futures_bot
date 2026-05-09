# frozen_string_literal: true

require 'fileutils'
require 'sqlite3'

module CoindcxBot
  module Persistence
    # Versioned, idempotent SQLite migration runner. Tracks applied migrations
    # in a `schema_migrations` table so the runner can be invoked on every
    # boot without re-applying or duplicating work.
    #
    # Migrations are objects exposing `version` (Integer), `name` (String),
    # and `up(db)` (executes SQL via the passed `SQLite3::Database`). Use
    # `register` to add migrations and `run!` to apply pending ones in
    # version order. Down migrations are intentionally unsupported — for
    # destructive change, write a forward-only migration that ALTERs.
    class MigrationRunner
      class Error < StandardError; end

      SCHEMA_TABLE_SQL = <<~SQL
        CREATE TABLE IF NOT EXISTS schema_migrations (
          version INTEGER PRIMARY KEY,
          name TEXT NOT NULL,
          applied_at INTEGER NOT NULL
        );
      SQL

      def initialize(db_path:, logger: nil)
        @db_path = db_path
        @logger = logger
        @migrations = []
      end

      def register(migration)
        validate_migration!(migration)
        raise Error, "duplicate migration version: #{migration.version}" if @migrations.any? { |m| m.version == migration.version }

        @migrations << migration
        self
      end

      def applied_versions
        db = open_db
        db.execute(SCHEMA_TABLE_SQL)
        db.execute('SELECT version FROM schema_migrations ORDER BY version').map { |r| r[0].to_i }
      ensure
        db&.close
      end

      def run!
        ensure_dir
        db = open_db
        db.execute('PRAGMA journal_mode=WAL')
        db.execute('PRAGMA busy_timeout=5000')
        db.execute(SCHEMA_TABLE_SQL)

        applied = db.execute('SELECT version FROM schema_migrations').flatten.to_set(&:to_i)

        sorted = @migrations.sort_by(&:version)
        sorted.each do |migration|
          next if applied.include?(migration.version)

          apply!(db, migration)
        end

        db.close
        self
      end

      private

      def apply!(db, migration)
        log(:info, 'migration_apply', version: migration.version, name: migration.name)
        db.transaction do
          migration.up(db)
          db.execute(
            'INSERT INTO schema_migrations(version, name, applied_at) VALUES(?, ?, ?)',
            [migration.version, migration.name, (Time.now.to_f * 1000).to_i]
          )
        end
      rescue StandardError => e
        log(:error, 'migration_failed', version: migration.version, name: migration.name, error: e.message)
        raise
      end

      def validate_migration!(migration)
        %i[version name up].each do |m|
          raise Error, "migration must respond to #{m}" unless migration.respond_to?(m)
        end
      end

      def ensure_dir
        dir = File.dirname(@db_path)
        FileUtils.mkdir_p(dir) unless File.directory?(dir) || @db_path == ':memory:'
      end

      def open_db
        SQLite3::Database.new(@db_path).tap { |db| db.results_as_hash = false }
      end

      def log(level, event, payload)
        return unless @logger

        @logger.public_send(level, event, payload)
      end
    end
  end
end
