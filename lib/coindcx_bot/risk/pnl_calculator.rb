# frozen_string_literal: true

require 'bigdecimal'

module CoindcxBot
  module Risk
    # Pure PnL computation module. All inputs/outputs are BigDecimal.
    # This is the ONLY place where PnL arithmetic should live — avoid
    # ad-hoc (exit_price - entry_price) * qty scattered across the codebase.
    #
    # CoinDCX futures PnL formula:
    #   realized_pnl = price_pnl - entry_fee - exit_fee - accumulated_funding
    #   price_pnl    = (exit - entry) * size  [long] | (entry - exit) * size  [short]
    module PnlCalculator
      # CoinDCX futures taker fee default (basis points). Can be overridden per call.
      DEFAULT_TAKER_FEE_BPS = BigDecimal('5')  # 0.05 %

      # ── Unrealized ────────────────────────────────────────────────────────────

      # Self-computed unrealized PnL using mark price (not exchange-provided value).
      # Mark price is what the margin engine uses; LTP and last-trade diverge during stress.
      def self.unrealized_usdt(entry_price:, mark_price:, size:, side:)
        ep = BigDecimal(entry_price.to_s)
        mp = BigDecimal(mark_price.to_s)
        sz = BigDecimal(size.to_s)

        side.to_sym == :long ? (mp - ep) * sz : (ep - mp) * sz
      rescue ArgumentError, TypeError
        BigDecimal('0')
      end

      # ── Fee helpers ──────────────────────────────────────────────────────────

      def self.fee_usdt(price:, size:, fee_bps: DEFAULT_TAKER_FEE_BPS)
        notional = BigDecimal(price.to_s) * BigDecimal(size.to_s)
        notional * BigDecimal(fee_bps.to_s) / 10_000
      rescue ArgumentError, TypeError
        BigDecimal('0')
      end

      # ── Realized ─────────────────────────────────────────────────────────────

      # Full realized PnL accounting for round-trip fees and accumulated funding.
      # `funding_paid_usdt` is positive when the trader paid (long in positive funding env.).
      def self.realized_usdt(entry_price:, exit_price:, size:, side:,
                             funding_paid_usdt: BigDecimal('0'),
                             entry_fee_bps: DEFAULT_TAKER_FEE_BPS,
                             exit_fee_bps:  DEFAULT_TAKER_FEE_BPS)
        ep  = BigDecimal(entry_price.to_s)
        xp  = BigDecimal(exit_price.to_s)
        sz  = BigDecimal(size.to_s)
        fpd = BigDecimal(funding_paid_usdt.to_s)

        price_pnl  = side.to_sym == :long ? (xp - ep) * sz : (ep - xp) * sz
        entry_fee  = fee_usdt(price: ep, size: sz, fee_bps: entry_fee_bps)
        exit_fee   = fee_usdt(price: xp, size: sz, fee_bps: exit_fee_bps)

        price_pnl - entry_fee - exit_fee - fpd
      rescue ArgumentError, TypeError
        BigDecimal('0')
      end

      # Required initial margin for a new position.
      def self.required_initial_margin(entry_price:, size:, leverage:)
        notional = BigDecimal(entry_price.to_s) * BigDecimal(size.to_s)
        notional / BigDecimal(leverage.to_s)
      rescue ArgumentError, TypeError, ZeroDivisionError
        BigDecimal('0')
      end
    end
  end
end
