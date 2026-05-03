# frozen_string_literal: true

require_relative 'migration_runner'
require_relative 'migrations/canonical_tables'

module CoindcxBot
  module Persistence
    # Registry of all migrations. Order is determined by `version`, not by
    # the order they appear here.
    module Migrations
      ALL = [
        Migrations::CanonicalTables.new,
      ].freeze

      def self.runner_for(db_path:, logger: nil)
        runner = MigrationRunner.new(db_path: db_path, logger: logger)
        ALL.each { |m| runner.register(m) }
        runner
      end
    end
  end
end
