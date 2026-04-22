# frozen_string_literal: true

require 'bigdecimal'

module CoindcxBot
  module Risk
    # Pre-trade margin simulator: answers "can we safely open this position?"
    # BEFORE sending an order to the exchange.
    #
    # Without this check the exchange can silently reject orders with
    # "insufficient margin" — or worse, open them at a higher leverage than
    # intended due to the cross-margin pool being partially exhausted.
    class MarginSimulator
      # Maximum age of account state before pre-trade check is skipped.
      STATE_STALE_SECONDS = 120

      def initialize(config:, logger: nil)
        @config = config
        @logger = logger
        @state       = nil
        @state_mutex = Mutex.new
        @updated_at  = nil
      end

      # Updated by the engine each time the futures wallet is refreshed.
      def update(account_state)
        @state_mutex.synchronize do
          @state      = account_state
          @updated_at = Time.now
        end
      end

      # Returns [:ok, nil] or [:reject, reason_string].
      # Fail-open: if account state is unavailable or stale, allows the order
      # (the exchange is the last-resort gate in that case).
      def pre_trade_ok?(entry_price:, quantity:, leverage:)
        state = @state_mutex.synchronize { @state }

        if state.nil? || state.source == :unavailable
          @logger&.debug('[margin_sim] no account state — skipping pre-trade check (fail-open)')
          return [:ok, nil]
        end

        if @updated_at && (Time.now - @updated_at) > STATE_STALE_SECONDS
          @logger&.warn('[margin_sim] account state stale — skipping pre-trade check (fail-open)')
          return [:ok, nil]
        end

        required = PnlCalculator.required_initial_margin(
          entry_price: entry_price,
          size:        quantity,
          leverage:    leverage
        )

        buffer_pct = @config.margin_safety_buffer_pct
        unless state.sufficient_margin?(required, buffer_pct: buffer_pct)
          avail = state.available_margin_usdt&.round(4)
          safe  = avail ? (avail * (1 - BigDecimal(buffer_pct.to_s) / 100)).round(4) : 'unknown'
          return [:reject,
                  "insufficient_margin: need #{required.round(4)} USDT; safe_available=#{safe} USDT " \
                  "(#{buffer_pct}% buffer)"]
        end

        max_ratio = @config.max_margin_ratio_pct
        ratio = state.margin_ratio
        if ratio && ratio * 100 > max_ratio
          return [:reject,
                  "margin_ratio #{(ratio * 100).round(1)}% exceeds max #{max_ratio}%"]
        end

        [:ok, nil]
      end
    end
  end
end
