# frozen_string_literal: true

require 'yaml'

module CoindcxBot
  class Config
    DEFAULT_PATH = File.expand_path('../../config/bot.yml', __dir__)

    attr_reader :raw

    def self.load(path = nil)
      path ||= ENV.fetch('COINDCX_BOT_CONFIG', DEFAULT_PATH)
      expanded = File.expand_path(path)
      raise ConfigurationError, "Missing config: #{expanded}" unless File.file?(expanded)

      new(YAML.safe_load(File.read(expanded), permitted_classes: [Symbol], aliases: true))
    end

    def initialize(hash)
      @raw = deep_symbolize(hash || {})
      validate_whitelist!
    end

    def pairs
      Array(raw[:pairs]).map(&:to_s)
    end

    def margin_currency_short_name
      raw[:margin_currency_short_name].to_s
    end

    def inr_per_usdt
      BigDecimal(raw.fetch(:inr_per_usdt, 83).to_s)
    end

    def risk
      raw.fetch(:risk, {})
    end

    def strategy
      raw.fetch(:strategy, {})
    end

    def execution
      raw.fetch(:execution, {})
    end

    def runtime
      raw.fetch(:runtime, {})
    end

    def dry_run?
      !!runtime[:dry_run]
    end

    def journal_path
      File.expand_path(runtime.fetch(:journal_path, './data/bot_journal.sqlite3'), Dir.pwd)
    end

    class ConfigurationError < StandardError; end

    private

    def validate_whitelist!
      allowed = pairs.uniq
      raise ConfigurationError, 'config pairs must list 1–2 instruments' unless allowed.size.between?(1, 2)

      allowed.each do |p|
        raise ConfigurationError, "Invalid pair #{p.inspect}" unless p.match?(/\A[A-Z0-9._-]+\z/i)
      end
    end

    def deep_symbolize(obj)
      case obj
      when Hash
        obj.each_with_object({}) { |(k, v), h| h[k.to_sym] = deep_symbolize(v) }
      when Array
        obj.map { |e| deep_symbolize(e) }
      else
        obj
      end
    end
  end
end
