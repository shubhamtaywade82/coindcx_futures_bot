# frozen_string_literal: true

require 'bigdecimal'

module CoindcxBot
  module Strategy
    # Mark-to-market unrealized PnL in USDT for a journal position row + LTP (same math as TUI).
    module UnrealizedPnl
      module_function

      def position_usdt(position, ltp)
        return nil if ltp.nil? || position.nil?

        q = BigDecimal((position[:quantity] || position['quantity']).to_s)
        e = BigDecimal((position[:entry_price] || position['entry_price']).to_s)
        l = BigDecimal(ltp.to_s)
        case (position[:side] || position['side']).to_s
        when 'long', 'buy'
          (l - e) * q
        when 'short', 'sell'
          (e - l) * q
        else
          BigDecimal('0')
        end
      rescue ArgumentError, TypeError
        nil
      end
    end
  end
end
