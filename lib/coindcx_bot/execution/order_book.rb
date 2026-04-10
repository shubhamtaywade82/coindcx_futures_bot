# frozen_string_literal: true

require 'bigdecimal'

module CoindcxBot
  module Execution
    # In-memory working orders for paper simulation. SQLite (`PaperStore`) is source of truth;
    # this book is rebuilt on `PaperBroker` boot and kept in sync as phases B+ wire `process_tick`.
    class OrderBook
      WorkingOrder = Data.define(
        :id,
        :pair,
        :side,
        :order_type,
        :quantity,
        :anchor_price,
        :limit_price,
        :stop_price,
        :group_id,
        :group_role
      )

      def initialize
        @mutex = Mutex.new
        @orders = {}
      end

      def reconcile_from_store(store)
        rows = store.working_orders
        @mutex.synchronize do
          @orders.clear
          rows.each { |row| @orders[row[:id]] = row_to_working(row) }
        end
        self
      end

      def add_from_row(row)
        wo = row_to_working(row)
        @mutex.synchronize { @orders[wo.id] = wo }
        wo
      end

      def add(id, pair:, side:, order_type:, quantity:, anchor_price: nil, limit_price: nil, stop_price: nil,
              group_id: nil, group_role: nil)
        wo = WorkingOrder.new(
          id: id,
          pair: pair.to_s,
          side: side.to_s,
          order_type: order_type.to_s,
          quantity: bd(quantity),
          anchor_price: optional_bd(anchor_price),
          limit_price: optional_bd(limit_price),
          stop_price: optional_bd(stop_price),
          group_id: group_id,
          group_role: group_role&.to_s
        )
        @mutex.synchronize { @orders[id] = wo }
        wo
      end

      def remove(id)
        @mutex.synchronize { @orders.delete(id) }
      end

      def find(id)
        @mutex.synchronize { @orders[id] }
      end

      def working_for(pair)
        p = pair.to_s
        @mutex.synchronize { @orders.values.select { |o| o.pair == p } }
      end

      def update_stop(id, new_stop)
        @mutex.synchronize do
          existing = @orders[id]
          return unless existing

          @orders[id] = WorkingOrder.new(
            id: existing.id,
            pair: existing.pair,
            side: existing.side,
            order_type: existing.order_type,
            quantity: existing.quantity,
            anchor_price: existing.anchor_price,
            limit_price: existing.limit_price,
            stop_price: optional_bd(new_stop),
            group_id: existing.group_id,
            group_role: existing.group_role
          )
        end
      end

      def clear
        @mutex.synchronize { @orders.clear }
      end

      def size
        @mutex.synchronize { @orders.size }
      end

      # TUI / snapshot: serializable rows for working orders only.
      def working_snapshot
        @mutex.synchronize do
          @orders.values.map do |wo|
            {
              id: wo.id,
              pair: wo.pair,
              side: wo.side,
              order_type: wo.order_type,
              quantity: wo.quantity.to_s('F'),
              limit_price: wo.limit_price&.to_s('F'),
              stop_price: wo.stop_price&.to_s('F')
            }
          end
        end
      end

      private

      def row_to_working(row)
        WorkingOrder.new(
          id: row[:id],
          pair: row[:pair].to_s,
          side: row[:side].to_s,
          order_type: row[:order_type].to_s,
          quantity: bd(row[:quantity]),
          anchor_price: optional_bd(row[:price]),
          limit_price: optional_bd(row[:limit_price]),
          stop_price: optional_bd(row[:stop_price]),
          group_id: row[:group_id],
          group_role: row[:group_role]&.to_s
        )
      end

      def bd(v)
        BigDecimal(v.to_s)
      end

      def optional_bd(v)
        return nil if v.nil? || v.to_s.strip.empty?

        BigDecimal(v.to_s)
      end
    end
  end
end
