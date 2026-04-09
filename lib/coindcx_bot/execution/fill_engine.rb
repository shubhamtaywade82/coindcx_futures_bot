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

      # Duck-typed `order`: #order_type, #side, #quantity, #limit_price, #stop_price (OrderBook::WorkingOrder).
      def evaluate(order, ltp:, high: nil, low: nil)
        return nil if ltp.nil?

        ltp_bd = BigDecimal(ltp.to_s)
        return nil if ltp_bd <= 0

        ot = order.order_type.to_s.downcase
        case ot
        when 'market', 'market_order'
          mk = fill_market_order(side: order.side, quantity: order.quantity, ltp: ltp_bd)
          mk.merge(trigger: :market_order)
        when 'limit', 'limit_order'
          evaluate_limit_order(order, ltp: ltp_bd, high: high, low: low)
        when 'stop', 'stop_market', 'stop_loss'
          evaluate_stop_like(order, ltp: ltp_bd, high: high, low: low, kind: :stop_loss)
        when 'take_profit', 'take_profit_market'
          evaluate_stop_like(order, ltp: ltp_bd, high: high, low: low, kind: :take_profit)
        end
      end

      def fill_market_order(side:, quantity:, ltp:)
        price = BigDecimal(ltp.to_s)
        qty = BigDecimal(quantity.to_s)

        fill_price = apply_slippage(price, side)
        fee = (fill_price * qty * @fee_rate).abs
        slippage = (fill_price - price).abs * qty

        { fill_price: fill_price, quantity: qty, fee: fee, slippage: slippage }
      end

      private

      def evaluate_limit_order(order, ltp:, high:, low:)
        limit = order.limit_price
        return nil if limit.nil?

        limit = BigDecimal(limit.to_s)
        side = order.side.to_s.downcase
        hi = high ? BigDecimal(high.to_s) : ltp
        lo = low ? BigDecimal(low.to_s) : ltp

        touched = case side
                  when 'long', 'buy'
                    ltp <= limit || lo <= limit
                  when 'short', 'sell'
                    ltp >= limit || hi >= limit
                  else
                    false
                  end
        return nil unless touched

        qty = BigDecimal(order.quantity.to_s)
        fee = (limit * qty * @fee_rate).abs
        {
          fill_price: limit,
          quantity: qty,
          fee: fee,
          slippage: BigDecimal('0'),
          trigger: :limit_order
        }
      end

      def evaluate_stop_like(order, ltp:, high:, low:, kind:)
        sp = order.stop_price
        return nil if sp.nil?

        sp = BigDecimal(sp.to_s)
        side = order.side.to_s.downcase
        hi = high ? BigDecimal(high.to_s) : ltp
        lo = low ? BigDecimal(low.to_s) : ltp

        triggered =
          case kind
          when :stop_loss
            case side
            when 'sell' then ltp <= sp || lo <= sp
            when 'buy'  then ltp >= sp || hi >= sp
            else false
            end
          when :take_profit
            case side
            when 'sell' then ltp >= sp || hi >= sp
            when 'buy'  then ltp <= sp || lo <= sp
            else false
            end
          else false
          end
        return nil unless triggered

        trig = kind == :stop_loss ? :stop_loss : :take_profit
        fill_market_order(side: order.side, quantity: order.quantity, ltp: ltp).merge(trigger: trig)
      end

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
