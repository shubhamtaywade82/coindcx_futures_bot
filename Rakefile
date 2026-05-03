# frozen_string_literal: true

require 'rspec/core/rake_task'
require 'rubocop/rake_task'

RSpec::Core::RakeTask.new(:spec)
RuboCop::RakeTask.new(:rubocop)

desc 'Run full quality gate (rubocop + rspec)'
task ci: %i[rubocop spec]

task default: :ci
