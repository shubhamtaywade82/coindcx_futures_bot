# frozen_string_literal: true

require 'bigdecimal'

module CoindcxBot
  module Risk
    class Manager
      def initialize(config:, journal:, exposure_guard:)
        @config = config
        @journal = journal
        @guard = exposure_guard
        @max_risk = BigDecimal(config.risk.fetch(:per_trade_inr_max, 500).to_s)
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
        risk_inr = @max_risk
        risk_usdt = risk_inr / @config.inr_per_usdt
        dist = (entry_price - stop_price).abs
        return BigDecimal('0') if dist <= 0

        (risk_usdt / dist).round(6, BigDecimal::ROUND_DOWN)
      end
    end
  end
end
