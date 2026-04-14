# frozen_string_literal: true

require 'bigdecimal'

module CoindcxBot
  module Risk
    class Manager
      def initialize(config:, journal:, exposure_guard:, fx:)
        @config = config
        @journal = journal
        @guard = exposure_guard
        @fx = fx
        @max_daily_loss = BigDecimal(config.resolved_max_daily_loss_inr.to_s)
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

        cb = evaluate_circuit_breaker
        return [:reject, cb] if cb

        [:ok, nil]
      end

      def evaluate_circuit_breaker
        limit = @config.risk.fetch(:consecutive_loss_limit, 3)
        return nil if limit <= 0

        # Look at the most recent realized trades to see if they are a streak of losses
        recent = @journal.recent_events(limit).select { |e| e['type'] == 'paper_realized' }
        return nil if recent.size < limit

        recent_losses = recent.take(limit).all? do |e|
          payload = JSON.parse(e['payload'] || '{}')
          pnl = BigDecimal(payload['pnl_usdt'] || '0')
          pnl.negative?
        end

        return nil unless recent_losses

        # Check if the streak happened recently (within the last hour)
        last_loss = recent.first
        return nil unless last_loss
        
        cooldown = @config.risk.fetch(:circuit_breaker_cooldown_minutes, 60)
        return nil if Time.now.to_i - last_loss['ts'].to_i > (cooldown * 60)

        "circuit_breaker_streak"
      end

      def size_quantity(entry_price:, stop_price:, side:)
        risk_inr = per_trade_risk_inr
        risk_usdt = risk_inr / @fx.inr_per_usdt
        dist = (entry_price - stop_price).abs
        return BigDecimal('0') if dist <= 0

        (risk_usdt / dist).round(6, BigDecimal::ROUND_DOWN)
      end

      private

      def per_trade_risk_inr
        rk = @config.risk
        min_r = @config.resolved_per_trade_inr_min
        max_r = @config.resolved_per_trade_inr_max
        cap = @config.capital_inr
        pct_raw = rk[:per_trade_capital_pct]

        if pct_raw.nil? || pct_raw.to_s.strip.empty?
          if cap && !@config.legacy_per_trade_inr_band?
            pct_raw = '1.5'
          else
            return (min_r + max_r) / 2
          end
        end

        pct = BigDecimal(pct_raw.to_s)
        return (min_r + max_r) / 2 if cap.nil?

        raw_budget = (cap * pct / 100).round(2, BigDecimal::ROUND_DOWN)
        clamp_inr_budget(raw_budget, min_r, max_r)
      end

      def clamp_inr_budget(value, min_r, max_r)
        v = [value, min_r].max
        [v, max_r].min
      end
    end
  end
end
