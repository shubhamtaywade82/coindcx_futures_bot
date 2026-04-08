# frozen_string_literal: true

require 'bigdecimal'

module CoindcxBot
  module Execution
    class Coordinator
      def initialize(order_gateway:, account_gateway:, journal:, config:, exposure_guard:, logger:)
        @orders = order_gateway
        @account = account_gateway
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
        exit_exchange_for_pair(pair) unless @dry
        @journal.open_positions.select { |row| row[:pair] == pair }.each do |row|
          @journal.close_position(row[:id])
        end
        :ok
      end

      def apply(signal, quantity: nil, entry_price: nil)
        case signal.action
        when :hold
          :ok
        when :open_long, :open_short
          open_position(signal, quantity, entry_price)
        when :close
          close_journal_and_exchange(signal)
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
        if quantity.nil? || quantity <= 0
          @logger&.warn("Skip open — zero quantity for #{signal.pair}")
          return :rejected
        end

        ep = entry_price || BigDecimal('0')
        side = api_side(signal)
        body = {
          pair: signal.pair,
          side: side,
          total_quantity: quantity.to_s('F')
        }
        lev = effective_leverage
        unless @exposure.leverage_allowed?(lev)
          @logger&.warn("Skip open — leverage #{lev} exceeds max #{@exposure.max_leverage}")
          return :rejected
        end
        body[:leverage] = lev

        @journal.log_event('signal_open', action: signal.action.to_s, pair: signal.pair, reason: signal.reason,
                                          leverage: lev)

        if @dry
          @journal.insert_position(
            pair: signal.pair,
            side: signal.side.to_s,
            entry_price: ep,
            quantity: quantity,
            stop_price: signal.stop_price,
            trail_price: nil
          )
          @logger&.info("[dry_run] journal open (no exchange): #{body}")
          return :dry_run
        end

        result = @orders.create(order: body)
        if result.failure?
          @logger&.error("Order create failed: #{result.code} #{result.message}")
          return :failed
        end

        @journal.insert_position(
          pair: signal.pair,
          side: signal.side.to_s,
          entry_price: ep,
          quantity: quantity,
          stop_price: signal.stop_price,
          trail_price: nil
        )
        @logger&.info("Opened #{signal.side} #{signal.pair} qty=#{quantity}")
        :ok
      end

      def api_side(signal)
        signal.side == :long ? 'buy' : 'sell'
      end

      def close_journal_and_exchange(signal)
        id = signal.metadata[:position_id]
        @journal.log_event('signal_close', pair: signal.pair, reason: signal.reason, position_id: id)

        if @dry
          @journal.close_position(id) if id
          @logger&.info("[dry_run] close #{signal.pair} id=#{id}")
          return :dry_run
        end

        exit_exchange_for_pair(signal.pair)
        @journal.close_position(id) if id
        :ok
      end

      def exit_exchange_for_pair(pair)
        res = @account.list_positions
        if res.failure?
          @logger&.error("positions list failed: #{res.message}")
          return
        end

        normalize_rows(res.value).each do |row|
          next unless row[:pair].to_s == pair.to_s

          x = @account.exit_position(row)
          @logger&.warn("exit_position failed: #{x.message}") if x.failure?
        end
      end

      # Records 1R partial in the journal so trailing logic can treat the position as scaled.
      # CoinDCX reduce-only / close-partial payloads vary by account and product; the generic
      # `Models::Order` in coindcx-client does not encode contract-specific fields. Until a
      # verified `futures.orders.create` body exists for partial exits, we do not place a
      # reduce order here — see README "Partial at 1R".
      def handle_partial(signal)
        id = signal.metadata[:position_id]
        @journal.log_event('signal_partial', pair: signal.pair, position_id: id)
        @journal.mark_partial(id) if id
        @logger&.info("Partial at 1R recorded for position #{id} (reduce on exchange not auto-placed)")
        :ok
      end

      def trail_stop(signal)
        id = signal.metadata[:position_id]
        return :ok unless id && signal.stop_price

        @journal.update_position_stop(id, signal.stop_price)
        @journal.log_event('trail', position_id: id, stop: signal.stop_price.to_s('F'))
        :ok
      end

      def effective_leverage
        defaults = @config.execution.fetch(:order_defaults, {})
        raw = defaults[:leverage] || defaults['leverage'] || @config.risk.fetch(:max_leverage, 5)
        requested = Integer(raw)
        cap = @exposure.max_leverage
        [[requested, 1].max, cap].min
      end

      def normalize_rows(value)
        list =
          case value
          when Array then value
          when Hash
            value[:positions] || value['positions'] || value[:data] || value.values.find { |v| v.is_a?(Array) } || []
          else
            []
          end
        Array(list).map { |h| h.is_a?(Hash) ? h.transform_keys(&:to_sym) : {} }
      end
    end
  end
end
