# frozen_string_literal: true

require 'json'
require 'bigdecimal'

module CoindcxBot
  module PaperExchange
    class MarketRules
      DEFAULT_TYPES = %w[market_order limit_order stop_limit take_profit].freeze

      def initialize(store)
        @db = store.db
      end

      def ensure_pair!(pair)
        p = pair.to_s
        row = @db.get_first_row('SELECT * FROM pe_market_rules WHERE pair = ?', [p])
        return symbolize(row) if row

        @db.execute(
          <<~SQL,
            INSERT INTO pe_market_rules (pair, min_quantity, max_quantity, price_precision, quantity_precision,
              allowed_order_types, market_status)
            VALUES (?, '0.001', NULL, 8, 8, ?, 'active')
          SQL
          [p, JSON.generate(DEFAULT_TYPES)]
        )
        symbolize(@db.get_first_row('SELECT * FROM pe_market_rules WHERE pair = ?', [p]))
      end

      def validate_quantity!(pair, qty)
        rules = ensure_pair!(pair)
        raise ValidationError, 'market inactive' unless rules[:market_status].to_s == 'active'

        q = BigDecimal(qty.to_s)
        min_q = BigDecimal(rules[:min_quantity].to_s)
        max_q = rules[:max_quantity] && !rules[:max_quantity].to_s.empty? ? BigDecimal(rules[:max_quantity].to_s) : nil
        raise ValidationError, 'quantity below minimum' if q < min_q
        raise ValidationError, 'quantity above maximum' if max_q && q > max_q

        q
      end

      def validate_order_type!(pair, order_type)
        rules = ensure_pair!(pair)
        allowed = JSON.parse(rules[:allowed_order_types].to_s)
        return if allowed.include?(order_type.to_s)

        raise ValidationError, 'order type not allowed for market'
      end

      class ValidationError < StandardError; end

      private

      def symbolize(row)
        row.transform_keys(&:to_sym)
      end
    end
  end
end
