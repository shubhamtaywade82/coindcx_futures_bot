# frozen_string_literal: true

require 'bigdecimal'
require 'yaml'
require_relative 'scalper_profile'

module CoindcxBot
  class Config
    DEFAULT_PATH = File.expand_path('../../config/bot.yml', __dir__)

    # Upper bound for `pairs:` (WS subs, REST poll, and TUI rows scale with count).
    MAX_PAIRS = 32

    attr_reader :raw

    def self.scalper_mode_requested?(raw_hash)
      env = ENV[ScalperProfile::ENV_KEY].to_s.strip.downcase
      return false if %w[swing default].include?(env)
      return true if env == 'scalper'

      raw_hash.dig(:runtime, :mode)&.to_s&.strip&.downcase == 'scalper'
    end

    def self.load(path = nil)
      path ||= ENV.fetch('COINDCX_BOT_CONFIG', DEFAULT_PATH)
      expanded = File.expand_path(path)
      raise ConfigurationError, "Missing config: #{expanded}" unless File.file?(expanded)

      new(YAML.safe_load(File.read(expanded), permitted_classes: [Symbol], aliases: true))
    end

    def initialize(hash)
      @raw = deep_symbolize(hash || {})
      @scalper_mode = self.class.scalper_mode_requested?(@raw)
      @raw = deep_merge_defaults(@raw, ScalperProfile::OVERLAY) if @scalper_mode
      validate_whitelist!
      validate_risk_pct_sanity!
      validate_risk_band!
      validate_risk_capital_pct!
    end

    def scalper_mode?
      @scalper_mode
    end

    def trading_mode_label
      @scalper_mode ? 'SCALP' : 'SWING'
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

    # Reference equity in INR (position sizing when `risk.per_trade_capital_pct` is set; TUI header).
    def capital_inr
      v = raw[:capital_inr] || raw['capital_inr']
      return nil if v.nil? || v.to_s.strip.empty?

      BigDecimal(v.to_s)
    rescue ArgumentError, TypeError
      nil
    end

    # True when both INR clamps are set explicitly (legacy YAML). Otherwise clamps scale from `capital_inr`.
    def legacy_per_trade_inr_band?
      rk = risk
      risk_value_present?(rk, :per_trade_inr_min) && risk_value_present?(rk, :per_trade_inr_max)
    end

    # Per-trade floor in INR: explicit `per_trade_inr_min`, else `capital_inr` × min_pct/100, else ₹250.
    def resolved_per_trade_inr_min
      rk = risk
      if risk_value_present?(rk, :per_trade_inr_min)
        BigDecimal(rk[:per_trade_inr_min].to_s)
      elsif (cap = capital_inr)
        p = BigDecimal(rk.fetch(:per_trade_inr_min_pct_of_capital, 0.25).to_s)
        (cap * p / 100).round(2, BigDecimal::ROUND_DOWN)
      else
        BigDecimal('250')
      end
    end

    # Per-trade ceiling in INR: explicit `per_trade_inr_max`, else `capital_inr` × max_pct/100, else ₹500.
    def resolved_per_trade_inr_max
      rk = risk
      if risk_value_present?(rk, :per_trade_inr_max)
        BigDecimal(rk[:per_trade_inr_max].to_s)
      elsif (cap = capital_inr)
        p = BigDecimal(rk.fetch(:per_trade_inr_max_pct_of_capital, 3.0).to_s)
        (cap * p / 100).round(2, BigDecimal::ROUND_DOWN)
      else
        BigDecimal('500')
      end
    end

    # Daily loss halt: explicit `max_daily_loss_inr`, else `capital_inr` × loss_pct/100, else ₹1500.
    def resolved_max_daily_loss_inr
      rk = risk
      if risk_value_present?(rk, :max_daily_loss_inr)
        BigDecimal(rk[:max_daily_loss_inr].to_s)
      elsif (cap = capital_inr)
        p = BigDecimal(rk.fetch(:max_daily_loss_pct_of_capital, 3.5).to_s)
        (cap * p / 100).round(2, BigDecimal::ROUND_DOWN)
      else
        BigDecimal('1500')
      end
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

    def regime_section
      raw.fetch(:regime, {})
    end

    def regime_enabled?
      truthy?(regime_section[:enabled])
    end

    def regime_ai_section
      rs = regime_section
      return {} unless rs.is_a?(Hash)

      rs.fetch(:ai, {})
    end

    def regime_ai_enabled?
      regime_enabled? && truthy?(regime_ai_section[:enabled])
    end

    def regime_ai_model
      regime_ai_section[:model].to_s.strip
    end

    def regime_ai_min_interval_seconds
      regime_ai_section.fetch(:min_interval_seconds, 180).to_f
    end

    def regime_ai_timeout_seconds
      regime_ai_section.fetch(:timeout_seconds, 90).to_i
    end

    def regime_ai_bars_per_pair
      n = regime_ai_section.fetch(:bars_per_pair, 24).to_i
      [[n, 8].max, 96].min
    end

    def regime_ai_max_pairs
      n = regime_ai_section.fetch(:max_pairs, 8).to_i
      [[n, 1].max, MAX_PAIRS].min
    end

    def regime_ai_ollama_base_url
      regime_ai_section[:ollama_base_url].to_s.strip
    end

    def regime_ai_temperature
      Float(regime_ai_section.fetch(:temperature, 0.15))
    rescue ArgumentError, TypeError
      0.15
    end

    def regime_ai_use_retry_middleware?
      truthy?(regime_ai_section.fetch(:use_retry_middleware, true))
    end

    def regime_ai_retry_attempts
      n = regime_ai_section.fetch(:retry_attempts, 3).to_i
      [[n, 1].max, 8].min
    end

    # Paper trading: no exchange orders or account exits. `runtime.paper` is an alias for `runtime.dry_run`.
    def dry_run?
      r = runtime
      !!(r[:dry_run] || r[:paper])
    end

    def paper_config
      raw.fetch(:paper, {})
    end

    def paper_exchange_enabled?
      dry_run? && truthy?(raw.dig(:paper_exchange, :enabled))
    end

    def paper_exchange_api_base
      raw.dig(:paper_exchange, :api_base_url).to_s.strip
    end

    def paper_exchange_tick_path
      p = raw.dig(:paper_exchange, :tick_path).to_s.strip
      p.empty? ? '/exchange/v1/paper/simulation/tick' : p
    end

    def journal_path
      File.expand_path(runtime.fetch(:journal_path, './data/bot_journal.sqlite3'), Dir.pwd)
    end

    class ConfigurationError < StandardError; end

    private

    # Fills in missing keys only (user YAML always wins on explicit keys).
    def deep_merge_defaults(base, defaults)
      return base if defaults.nil? || defaults.empty?

      b = base.is_a?(Hash) ? base.dup : {}
      defaults.each do |k, dv|
        if dv.is_a?(Hash) && b[k].is_a?(Hash)
          b[k] = deep_merge_defaults(b[k], dv)
        elsif !b.key?(k)
          b[k] = dv
        end
      end
      b
    end

    def truthy?(v)
      v == true || v.to_s.downcase == 'true' || v.to_s == '1'
    end

    def risk_value_present?(rk, key)
      rk.key?(key) && !(rk[key].nil? || rk[key].to_s.strip.empty?)
    end

    def validate_whitelist!
      allowed = pairs.uniq
      unless allowed.size.between?(1, MAX_PAIRS)
        raise ConfigurationError,
              "config pairs must list 1–#{MAX_PAIRS} instruments (got #{allowed.size})"
      end

      allowed.each do |p|
        raise ConfigurationError, "Invalid pair #{p.inspect}" unless p.match?(/\A[A-Z0-9._-]+\z/i)
      end
    end

    def validate_risk_band!
      min_r = resolved_per_trade_inr_min
      max_r = resolved_per_trade_inr_max
      return if min_r <= max_r

      raise ConfigurationError,
            'resolved per-trade INR min must be <= max (check capital_inr and risk.*_pct_of_capital or per_trade_inr_min/max)'
    end

    def validate_risk_pct_sanity!
      rk = raw[:risk] || {}
      min_p = BigDecimal(rk.fetch(:per_trade_inr_min_pct_of_capital, 0.25).to_s)
      max_p = BigDecimal(rk.fetch(:per_trade_inr_max_pct_of_capital, 3.0).to_s)
      return if min_p <= max_p

      raise ConfigurationError,
            'risk.per_trade_inr_min_pct_of_capital must be <= risk.per_trade_inr_max_pct_of_capital'

    rescue ArgumentError, TypeError
      raise ConfigurationError, 'risk per-trade *_pct_of_capital values must be numeric'
    end

    def validate_risk_capital_pct!
      rk = raw[:risk] || {}
      return unless risk_value_present?(rk, :per_trade_capital_pct)

      pct = BigDecimal(rk[:per_trade_capital_pct].to_s)
      raise ConfigurationError, 'risk.per_trade_capital_pct must be > 0' unless pct.positive?
      raise ConfigurationError, 'risk.per_trade_capital_pct must be <= 100' if pct > 100

      return unless capital_inr.nil?

      raise ConfigurationError, 'capital_inr is required when risk.per_trade_capital_pct is set'
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
