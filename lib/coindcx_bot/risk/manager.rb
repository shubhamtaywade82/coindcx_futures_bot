# frozen_string_literal: true

require 'bigdecimal'

module CoindcxBot
  module Risk
    class Manager
      def initialize(config:, journal:, exposure_guard:)
        @config = config
        @journal = journal
        @guard = exposure_guard
        @max_daily_loss = BigDecimal(config.risk.fetch(:max_daily_loss_inr, 1500).to_s)
      end

      def daily_loss_breached?
        @journal.daily_pnl_inr <= -@max_daily_loss
      end

      def allow_new_entry?(open_positions:, pair:)
        return [:reject, 'kill_switch'] if @journal.kill_switch?
        return [:reject, 'paused'] if @journal.paused?
        return [:reject, 'daily_loss'] if daily_loss_breached?
        return [:reject, 'symbol_already_open'] if open_positions.any? { |p| p[:pair] == pair }
        return [:reject, 'max_positions'] unless @guard.within_concurrency?(open_positions.size)

        [:ok, nil]
      end

      def size_quantity(entry_price:, stop_price:, side:)
        risk_inr = per_trade_risk_inr
        risk_usdt = risk_inr / @config.inr_per_usdt
        dist = (entry_price - stop_price).abs
        return BigDecimal('0') if dist <= 0

        (risk_usdt / dist).round(6, BigDecimal::ROUND_DOWN)
      end

      private

      def per_trade_risk_inr
        rk = @config.risk
        min_r = BigDecimal(rk.fetch(:per_trade_inr_min, 250).to_s)
        max_r = BigDecimal(rk.fetch(:per_trade_inr_max, 500).to_s)
        pct = rk[:per_trade_capital_pct]
        if pct.nil? || pct.to_s.strip.empty?
          return (min_r + max_r) / 2
        end

        cap = @config.capital_inr
        return (min_r + max_r) / 2 if cap.nil?

        raw_budget = (cap * BigDecimal(pct.to_s) / 100).round(2, BigDecimal::ROUND_DOWN)
        clamp_inr_budget(raw_budget, min_r, max_r)
      end

      def clamp_inr_budget(value, min_r, max_r)
        v = [value, min_r].max
        [v, max_r].min
      end
    end
  end
end
