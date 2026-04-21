# frozen_string_literal: true

require 'bigdecimal'

module CoindcxBot
  module Models
    # Normalized snapshot of the futures account. The exchange wallet response is
    # inconsistent (field names and precision vary); this model is the single
    # authoritative view used by MarginSimulator and PortfolioExposure.
    #
    # Source-of-truth rule:
    #   All trading decisions use THIS object, never raw API responses.
    AccountState = Struct.new(
      :equity_usdt,            # total wallet balance (cross margin)
      :available_margin_usdt,  # balance free for new positions
      :used_margin_usdt,       # initial margin locked in open positions
      :cross_order_margin,     # margin reserved for pending orders
      :cross_user_margin,      # user-reserved margin (manual)
      :margin_ratio,           # used_margin / equity (0..1); nil if unknown
      :currency,               # always 'USDT' for futures
      :fetched_at,             # Time of last refresh
      :source,                 # :live | :estimated | :unavailable
      keyword_init: true
    ) do
      # Returns the % of equity currently consumed by open positions.
      def margin_utilization_pct
        return BigDecimal('0') unless equity_usdt && !equity_usdt.zero?

        ((used_margin_usdt || BigDecimal('0')) / equity_usdt * 100).round(2)
      end

      # True when opening a position with `required_margin` USDT would not
      # breach the configured safety buffer.
      def sufficient_margin?(required_margin_usdt, buffer_pct: 20)
        return true unless available_margin_usdt  # fail-open when state unknown

        buffer    = BigDecimal(buffer_pct.to_s) / 100
        safe_avail = available_margin_usdt * (1 - buffer)
        required_margin_usdt <= safe_avail
      end

      # Builds an AccountState from the wallet snapshot hash produced by
      # `Tui::LiveAccountMirror.extract_wallet_snapshot_for_display`.
      def self.from_wallet_snapshot(snap)
        return unavailable if snap.nil? || snap.empty?

        equity    = decimal_or_nil(snap[:balance])
        available = decimal_or_nil(snap[:available_balance])
        locked    = decimal_or_nil(snap[:locked_balance])
        com       = decimal_or_nil(snap[:cross_order_margin])
        cum       = decimal_or_nil(snap[:cross_user_margin])

        used = if equity && available
                 [equity - available, BigDecimal('0')].max
               else
                 locked || BigDecimal('0')
               end

        ratio = (equity && !equity.zero?) ? (used / equity).round(6) : nil

        new(
          equity_usdt:           equity,
          available_margin_usdt: available,
          used_margin_usdt:      used,
          cross_order_margin:    com,
          cross_user_margin:     cum,
          margin_ratio:          ratio,
          currency:              snap[:currency]&.to_s || 'USDT',
          fetched_at:            Time.now,
          source:                :live
        )
      end

      def self.unavailable
        new(
          equity_usdt: nil, available_margin_usdt: nil, used_margin_usdt: BigDecimal('0'),
          margin_ratio: nil, currency: 'USDT', fetched_at: Time.now, source: :unavailable
        )
      end

      private_class_method def self.decimal_or_nil(v)
        return nil if v.nil?

        BigDecimal(v.to_s)
      rescue ArgumentError, TypeError
        nil
      end
    end
  end
end
