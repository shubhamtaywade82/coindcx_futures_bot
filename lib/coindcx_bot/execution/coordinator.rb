# frozen_string_literal: true

require 'bigdecimal'

module CoindcxBot
  module Execution
    class Coordinator
      def initialize(broker:, journal:, config:, exposure_guard:, logger:)
        @broker = broker
        @journal = journal
        @config = config
        @exposure = exposure_guard
        @logger = logger
        @dry = config.dry_run?
      end

      def flatten_all(pairs)
        pairs.each { |pair| flatten_pair(pair) }
      end

      def flatten_pair(pair)
        @journal.log_event('flatten', pair: pair)
        @broker.close_position(pair: pair, side: nil, quantity: 0, ltp: 0) unless @broker.paper?

        @journal.open_positions.select { |row| row[:pair] == pair }.each do |row|
          @journal.close_position(row[:id])
        end
        :ok
      end

      def apply(signal, quantity: nil, entry_price: nil, exit_price: nil)
        case signal.action
        when :hold
          :ok
        when :open_long, :open_short
          open_position(signal, quantity, entry_price)
        when :close
          close_position(signal, exit_price: exit_price)
        when :partial
          handle_partial(signal)
        when :trail
          trail_stop(signal)
        else
          @logger&.warn("Unknown signal action: #{signal.action}")
          :ignored
        end
      end

      private

      def open_position(signal, quantity, entry_price)
        return :rejected if quantity.nil? || quantity <= 0

        ep = entry_price || BigDecimal('0')
        lev = effective_leverage
        return :rejected unless leverage_permitted?(lev)

        @journal.log_event('signal_open', action: signal.action.to_s, pair: signal.pair, reason: signal.reason,
                                          leverage: lev)

        if @broker.paper?
          open_via_paper_broker(signal, quantity, ep, lev)
        else
          open_via_live_broker(signal, quantity, ep, lev)
        end
      end

      def open_via_paper_broker(signal, quantity, entry_price, leverage)
        result = @broker.place_order(
          pair: signal.pair,
          side: signal.side.to_s,
          quantity: quantity,
          ltp: entry_price,
          order_type: :market,
          leverage: leverage
        )

        journal_open(signal, quantity, entry_price)
        @logger&.info("[paper] opened #{signal.side} #{signal.pair} qty=#{quantity}")
        result == :ok ? :paper : :failed
      end

      def open_via_live_broker(signal, quantity, entry_price, leverage)
        body = {
          pair: signal.pair,
          side: api_side(signal),
          total_quantity: quantity.to_s('F'),
          leverage: leverage
        }

        result = @broker.place_order(body)
        if result == :failed
          @logger&.error("Live order failed for #{signal.pair}")
          return :failed
        end

        journal_open(signal, quantity, entry_price)
        @logger&.info("Opened #{signal.side} #{signal.pair} qty=#{quantity}")
        :ok
      end

      def journal_open(signal, quantity, entry_price)
        @journal.insert_position(
          pair: signal.pair,
          side: signal.side.to_s,
          entry_price: entry_price,
          quantity: quantity,
          stop_price: signal.stop_price,
          trail_price: nil
        )
      end

      def close_position(signal, exit_price: nil)
        meta = metadata_symbols(signal)
        raw_id = meta[:position_id]
        id = normalize_position_id(raw_id)
        row, close_id = resolve_close_target(signal.pair.to_s, id)

        log_close_warnings(signal, id, close_id, row)
        @journal.log_event('signal_close', pair: signal.pair, reason: signal.reason,
                                           position_id: close_id || id)

        if @broker.paper?
          close_via_paper_broker(signal, row, close_id, exit_price)
        else
          close_via_live_broker(signal, close_id, exit_price)
        end
      end

      def close_via_paper_broker(signal, row, close_id, exit_price)
        return :failed if close_id.nil?

        if row && exit_price
          ltp = BigDecimal(exit_price.to_s)
          qty = BigDecimal(row[:quantity].to_s)
          @broker.close_position(
            pair: signal.pair,
            side: row[:side],
            quantity: qty,
            ltp: ltp,
            position_id: nil
          )
          record_paper_realized_pnl(row, exit_price)
        end

        @journal.close_position(close_id)
        @logger&.info("[paper] closed #{signal.pair} id=#{close_id}")
        :paper
      end

      def close_via_live_broker(signal, close_id, exit_price)
        @broker.close_position(
          pair: signal.pair,
          side: nil,
          quantity: 0,
          ltp: exit_price || 0
        )
        @journal.close_position(close_id)
        :ok
      end

      def handle_partial(signal)
        id = signal.metadata[:position_id]
        @journal.log_event('signal_partial', pair: signal.pair, position_id: id)
        @journal.mark_partial(id) if id
        @logger&.info("Partial at 1R recorded for position #{id}")
        :ok
      end

      def trail_stop(signal)
        id = signal.metadata[:position_id]
        return :ok unless id && signal.stop_price

        @journal.update_position_stop(id, signal.stop_price)
        @journal.log_event('trail', position_id: id, stop: signal.stop_price.to_s('F'))
        :ok
      end

      def api_side(signal)
        signal.side == :long ? 'buy' : 'sell'
      end

      def metadata_symbols(signal)
        m = signal.metadata || {}
        m.transform_keys(&:to_sym)
      end

      def normalize_position_id(raw)
        return nil if raw.nil?
        return Integer(raw) if raw.is_a?(Integer)

        s = raw.to_s
        return Integer(s, 10) if s.match?(/\A\d+\z/)

        nil
      rescue ArgumentError, TypeError
        nil
      end

      def resolve_close_target(pair, position_id)
        if position_id
          pid = Integer(position_id)
          row = @journal.open_positions.find { |r| r[:id] == pid }
          return [row, row ? pid : nil]
        end

        return [nil, nil] unless @dry

        row = @journal.open_positions.find { |r| r[:pair].to_s == pair }
        [row, row&.dig(:id)]
      end

      def log_close_warnings(signal, id, close_id, row)
        if id && row.nil?
          @logger&.warn("Close: no matching open journal row (position_id=#{id}, pair=#{signal.pair})")
        elsif id.nil? && close_id && @dry
          @logger&.info("[paper] close inferred id=#{close_id} for #{signal.pair}")
        end
      end

      def record_paper_realized_pnl(row, exit_price)
        return if exit_price.nil?

        entry = BigDecimal(row[:entry_price].to_s)
        qty = BigDecimal(row[:quantity].to_s)
        ex = BigDecimal(exit_price.to_s)

        usdt_pnl =
          case row[:side].to_s
          when 'long' then (ex - entry) * qty
          when 'short' then (entry - ex) * qty
          else return
          end

        inr = usdt_pnl * @config.inr_per_usdt
        @journal.add_daily_pnl_inr(inr)
        @journal.log_event(
          'paper_realized',
          position_id: row[:id],
          pair: row[:pair],
          pnl_usdt: usdt_pnl.to_s('F'),
          pnl_inr: inr.to_s('F'),
          exit_price: ex.to_s('F')
        )
        @logger&.info("[paper] PnL ~₹#{inr.to_s('F')} (#{usdt_pnl.to_s('F')} USDT) #{row[:pair]} ##{row[:id]}")
      end

      def effective_leverage
        defaults = @config.execution.fetch(:order_defaults, {})
        raw = defaults[:leverage] || defaults['leverage'] || @config.risk.fetch(:max_leverage, 5)
        requested = Integer(raw)
        cap = @exposure.max_leverage
        [[requested, 1].max, cap].min
      end

      def leverage_permitted?(lev)
        return true if @exposure.leverage_allowed?(lev)

        @logger&.warn("Skip open — leverage #{lev} exceeds max #{@exposure.max_leverage}")
        false
      end
    end
  end
end
