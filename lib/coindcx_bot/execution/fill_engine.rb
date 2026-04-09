# frozen_string_literal: true

require 'bigdecimal'

module CoindcxBot
  module Execution
    class FillEngine
      def initialize(slippage_bps:, fee_bps:)
        @slippage_rate = BigDecimal(slippage_bps.to_s) / 10_000
        @fee_rate = BigDecimal(fee_bps.to_s) / 10_000
      end

      attr_reader :slippage_rate, :fee_rate

      def fill_market_order(side:, quantity:, ltp:)
        price = BigDecimal(ltp.to_s)
        qty = BigDecimal(quantity.to_s)

        fill_price = apply_slippage(price, side)
        fee = (fill_price * qty * @fee_rate).abs
        slippage = (fill_price - price).abs * qty

        { fill_price: fill_price, quantity: qty, fee: fee, slippage: slippage }
      end

      private

      def apply_slippage(price, side)
        case side.to_s
        when 'buy', 'long'
          price * (BigDecimal('1') + @slippage_rate)
        else
          price * (BigDecimal('1') - @slippage_rate)
        end
      end
    end
  end
end
