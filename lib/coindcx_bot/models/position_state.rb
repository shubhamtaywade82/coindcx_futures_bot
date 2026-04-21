# frozen_string_literal: true

require 'bigdecimal'

module CoindcxBot
  module Models
    # Authoritative in-memory view of a single open futures position.
    # All risk metrics (unrealized PnL, liquidation distance) are SELF-COMPUTED
    # from entry_price and mark_price — never trusting exchange-side values
    # which can lag, round, or omit funding.
    PositionState = Struct.new(
      :pair,
      :side,               # :long | :short
      :size,               # BigDecimal quantity
      :entry_price,        # BigDecimal average fill price (actual if available)
      :mark_price,         # BigDecimal current mark price (from WS tick)
      :liquidation_price,  # BigDecimal from exchange position API (nil if unknown)
      :leverage,
      :funding_paid_usdt,  # accumulated funding debits (BigDecimal)
      :fees_paid_usdt,     # entry + exit fees paid so far (BigDecimal)
      :journal_id,         # integer FK into positions table
      keyword_init: true
    ) do
      # Unrealized PnL using mark price, not LTP.
      # This is the value that the margin engine uses — not the exchange field.
      def self_computed_unrealized_usdt
        return nil unless mark_price && entry_price && size

        side == :long ? (mark_price - entry_price) * size : (entry_price - mark_price) * size
      end

      # PnL net of funding and fees already incurred.
      def net_unrealized_usdt
        u = self_computed_unrealized_usdt
        return nil unless u

        u - (funding_paid_usdt || BigDecimal('0')) - (fees_paid_usdt || BigDecimal('0'))
      end

      # Notional value at mark price.
      def notional_usdt
        return nil unless mark_price && size

        mark_price * size
      end

      # Distance from mark price to liquidation, as a percentage of mark price.
      # Smaller = closer to liquidation = higher risk.
      def risk_distance_pct
        return nil unless mark_price && liquidation_price && mark_price.positive?

        ((mark_price - liquidation_price).abs / mark_price * 100).round(4)
      end

      # Categorical risk level based on liquidation proximity.
      def liquidation_risk_level
        d = risk_distance_pct
        return :unknown unless d

        if    d < 2  then :critical   # < 2% — immediate danger
        elsif d < 5  then :high       # < 5% — reduce now
        elsif d < 10 then :moderate   # < 10% — monitor closely
        else              :safe
        end
      end

      # Required initial margin for this position (approximate).
      def initial_margin_usdt
        return nil unless entry_price && size && leverage && leverage.positive?

        (entry_price * size) / leverage
      end
    end
  end
end
