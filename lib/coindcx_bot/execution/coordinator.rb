# frozen_string_literal: true

require 'bigdecimal'
require 'securerandom'

module CoindcxBot
  module Execution
    class Coordinator
      def initialize(broker:, journal:, config:, exposure_guard:, logger:, fx:)
        @broker = broker
        @journal = journal
        @config = config
        @exposure = exposure_guard
        @logger = logger
        @fx = fx
        @dry = config.dry_run?
      end

      def flatten_all(pairs, ltps: {})
        pairs.each { |pair| flatten_pair(pair, ltp: ltps[pair] || ltps[pair.to_s] || ltps[pair.to_sym]) }
      end

      def reconcile_paper_state!
        return unless @broker.paper? && @broker.respond_to?(:open_positions)

        journal_pos = @journal.open_positions.map { |r| [r[:pair].to_s, r] }.to_h
        paper_pos = @broker.open_positions.map { |r| [r[:pair].to_s, r] }.to_h

        # 1. In Paper but NOT in Journal -> Crash between place_order & journal_open
        # Close paper position to sync with Journal.
        paper_pos.each do |pair, p_row|
          next if journal_pos.key?(pair)
          @logger&.warn("[reconcile] Paper position found for #{pair} without Journal entry. Closing to sync.")
          @broker.close_position(
            pair: pair,
            side: p_row[:side],
            quantity: BigDecimal(p_row[:quantity].to_s),
            ltp: p_row[:entry_price] ? BigDecimal(p_row[:entry_price].to_s) : BigDecimal('0'),
            position_id: p_row[:id]
          )
        end

        # 2. In Journal but NOT in Paper -> Journal thinks it's open, but exchange doesn't
        # Close journal position so TUI/engine reflects reality.
        journal_pos.each do |pair, j_row|
          next if paper_pos.key?(pair)
          @logger&.warn("[reconcile] Journal position found for #{pair} without Paper entry. Closing to sync.")
          @journal.close_position(j_row[:id])
          @journal.log_event(
            'signal_close',
            pair: pair,
            reason: 'startup_reconciliation',
            position_id: j_row[:id],
            outcome: 'reconciled_orphan',
            pnl_booked: false
          )
        end
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

      # Called by the engine when PaperBroker#process_tick fills a working exit order.
      # Syncs the journal and books INR PnL without re-closing through the strategy.
      def handle_broker_exit(pair:, realized_pnl_usdt:, fill_price:, position_id:, trigger:)
        row = @journal.open_positions.find { |r| r[:pair].to_s == pair.to_s }
        close_id = row&.dig(:id)

        if close_id
          book_inr_from_paper_close(
            { ok: true, realized_pnl_usdt: realized_pnl_usdt, fill_price: fill_price, position_id: position_id },
            row: row,
            pair: pair,
            source: :"broker_#{trigger}"
          )
          @journal.close_position(close_id)
          @logger&.info("[paper] broker exit synced: #{pair} id=#{close_id} trigger=#{trigger} pnl=#{realized_pnl_usdt&.to_s('F')}")
        else
          @logger&.warn("[paper] broker exit for #{pair} but no matching journal row")
        end
      end

      private

      def flatten_pair(pair, ltp: nil)
        pair_s = pair.to_s
        @journal.log_event('flatten', pair: pair_s)

        if @broker.paper?
          paper_flatten_pair(pair_s, ltp)
        elsif live_orders_disabled?
          @logger&.warn(
            "[live] flatten skipped for #{pair_s}: order placement disabled (runtime.place_orders / PLACE_ORDER)"
          )
          return :ok
        else
          @broker.close_position(pair: pair_s, side: nil, quantity: 0, ltp: 0)
        end

        @journal.open_positions.select { |row| row[:pair] == pair_s }.each do |row|
          @journal.close_position(row[:id])
        end
        :ok
      end

      def open_position(signal, quantity, entry_price)
        return :rejected if quantity.nil? || quantity <= 0

        ep = entry_price || BigDecimal('0')
        lev = effective_leverage
        return :rejected unless leverage_permitted?(lev)

        if @broker.paper?
          open_via_paper_broker(signal, quantity, ep, lev)
        else
          open_via_live_broker(signal, quantity, ep, lev)
        end
      end

      def open_via_paper_broker(signal, quantity, entry_price, leverage)
        # In-process {PaperBroker} expects duck-typed fills; {GatewayPaperBroker} uses {LiveBroker#place_order}
        # and the CoinDCX client (buy/sell, client_order_id, total_quantity, market_order).
        if @broker.is_a?(GatewayPaperBroker)
          result = @broker.place_order(rest_futures_open_order(signal, quantity, leverage))
          ok = result == :ok
        else
          order_params = {
            pair: signal.pair,
            side: signal.side.to_s,
            quantity: quantity,
            ltp: entry_price,
            order_type: :market,
            leverage: leverage
          }

          if signal.stop_price && @broker.respond_to?(:place_bracket_order)
            tp_price = compute_take_profit(signal.side, entry_price, signal.stop_price)
            result = @broker.place_bracket_order(
              order_params,
              sl_price: signal.stop_price,
              tp_price: tp_price
            )
            ok = result.is_a?(Hash) && result[:ok]
          else
            result = @broker.place_order(order_params)
            ok = result == :ok
          end
        end

        unless ok
          @journal.log_event(
            'open_failed',
            pair: signal.pair,
            action: signal.action.to_s,
            reason: signal.reason.to_s,
            leverage: leverage,
            detail: 'broker_rejected'
          )
          return :failed
        end

        journal_id = journal_open(signal, quantity, entry_price)
        sync_journal_entry_from_paper_fill(signal.pair.to_s, journal_id)
        @journal.log_event(
          'signal_open',
          action: signal.action.to_s,
          pair: signal.pair,
          reason: signal.reason.to_s,
          leverage: leverage
        )
        @logger&.info("[paper] opened #{signal.side} #{signal.pair} qty=#{quantity}")
        :paper
      end

      def open_via_live_broker(signal, quantity, entry_price, leverage)
        if live_orders_disabled?
          @journal.log_event(
            'open_failed',
            pair: signal.pair,
            action: signal.action.to_s,
            reason: signal.reason.to_s,
            leverage: leverage,
            detail: 'live_orders_disabled'
          )
          @logger&.warn(
            "[live] order placement disabled (runtime.place_orders / PLACE_ORDER) — skipping open for #{signal.pair}"
          )
          return :failed
        end

        result = @broker.place_order(rest_futures_open_order(signal, quantity, leverage))
        if result == :failed
          @journal.log_event(
            'open_failed',
            pair: signal.pair,
            action: signal.action.to_s,
            reason: signal.reason.to_s,
            leverage: leverage,
            detail: 'broker_rejected'
          )
          @logger&.error("Live order failed for #{signal.pair}")
          return :failed
        end

        journal_open(signal, quantity, entry_price)
        @journal.log_event(
          'signal_open',
          action: signal.action.to_s,
          pair: signal.pair,
          reason: signal.reason.to_s,
          leverage: leverage
        )
        @logger&.info("Opened #{signal.side} #{signal.pair} qty=#{quantity}")
        :ok
      end

      def journal_open(signal, quantity, entry_price)
        smc_id = smc_setup_id_from_signal(signal)
        @journal.insert_position(
          pair: signal.pair,
          side: signal.side.to_s,
          entry_price: entry_price,
          quantity: quantity,
          stop_price: signal.stop_price,
          trail_price: nil,
          initial_stop_price: signal.stop_price,
          smc_setup_id: smc_id
        )
      end

      def smc_setup_id_from_signal(signal)
        m = signal.metadata
        return nil unless m.is_a?(Hash)

        v = m[:smc_setup_id] || m['smc_setup_id']
        s = v&.to_s&.strip
        s&.empty? ? nil : s
      end

      def close_position(signal, exit_price: nil)
        meta = metadata_symbols(signal)
        raw_id = meta[:position_id]
        id = normalize_position_id(raw_id)
        row, close_id = resolve_close_target(signal.pair.to_s, id)

        log_close_warnings(signal, id, close_id, row)

        if close_id.nil?
          @journal.log_event(
            'signal_close',
            pair: signal.pair,
            reason: signal.reason.to_s,
            position_id: id,
            outcome: 'no_open_target',
            pnl_booked: false
          )
          return :failed
        end

        if @broker.paper?
          close_via_paper_broker(signal, row, close_id, exit_price)
        else
          close_via_live_broker(signal, close_id, exit_price)
        end
      end

      def close_via_paper_broker(signal, row, close_id, exit_price)
        skipped_no_ltp = false
        broker_res = nil
        exchange_attempted = false

        if row && paper_close_allowed?(exit_price)
          exchange_attempted = true
          ltp = paper_close_ltp(exit_price)
          qty = BigDecimal(row[:quantity].to_s)
          broker_res = @broker.close_position(
            pair: signal.pair.to_s,
            side: row[:side],
            quantity: qty,
            ltp: ltp,
            position_id: nil
          )
          book_inr_from_paper_close(broker_res, row: row, pair: signal.pair.to_s, source: :strategy_close)
        elsif row && exit_price.nil?
          skipped_no_ltp = true
          @logger&.warn(
            "[paper] close skipped for #{signal.pair}: no LTP (journal row #{close_id} still closed — sync flatten if needed)"
          )
        end

        @journal.close_position(close_id)
        @logger&.info("[paper] closed #{signal.pair} id=#{close_id}")

        outcome, pnl_flag = summarize_paper_close_outcome(broker_res, exchange_attempted, skipped_no_ltp)
        @journal.log_event(
          'signal_close',
          pair: signal.pair,
          reason: signal.reason.to_s,
          position_id: close_id,
          outcome: outcome,
          pnl_booked: pnl_flag
        )
        :paper
      end

      def close_via_live_broker(signal, close_id, exit_price)
        if live_orders_disabled?
          @journal.log_event(
            'signal_close',
            pair: signal.pair,
            reason: signal.reason.to_s,
            position_id: close_id,
            outcome: 'live_orders_disabled',
            pnl_booked: false
          )
          @logger&.warn(
            "[live] exit disabled (runtime.place_orders / PLACE_ORDER) — skipping close for #{signal.pair} id=#{close_id}"
          )
          return :failed
        end

        result = @broker.close_position(
          pair: signal.pair.to_s,
          side: nil,
          quantity: 0,
          ltp: exit_price || 0
        )
        row = @journal.open_positions.find { |r| r[:id] == close_id }
        pnl_path = paper_broker_close_result?(result) && result[:ok]
        if pnl_path
          book_inr_from_paper_close(
            result,
            row: row,
            pair: signal.pair.to_s,
            source: :strategy_close
          )
        end
        @journal.close_position(close_id)
        @journal.log_event(
          'signal_close',
          pair: signal.pair,
          reason: signal.reason.to_s,
          position_id: close_id,
          outcome: 'live_closed',
          pnl_booked: pnl_path
        )
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

        # Sync trailing stop to broker's working SL order
        if @broker.paper? && @broker.respond_to?(:update_trailing_stop)
          @broker.update_trailing_stop(pair: signal.pair, new_stop: signal.stop_price)
        end

        :ok
      end

      def api_side(signal)
        signal.side == :long ? 'buy' : 'sell'
      end

      def rest_futures_open_order(signal, quantity, leverage)
        {
          pair: signal.pair,
          side: api_side(signal),
          total_quantity: quantity.to_s('F'),
          leverage: leverage,
          order_type: 'market_order',
          client_order_id: "coindcx-bot-#{SecureRandom.uuid}"
        }
      end

      def live_orders_disabled?
        !@broker.paper? && !@config.place_orders?
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

      def paper_flatten_pair(pair, ltp)
        pos = @broker.open_position_for(pair)
        return if pos.nil?

        ltp_bd = coerce_ltp(ltp)
        unless ltp_bd
          @logger&.warn("paper flatten: no LTP for #{pair}, skipping PaperStore close")
          return
        end

        qty = BigDecimal(pos[:quantity].to_s)
        res = @broker.close_position(
          pair: pair,
          side: pos[:side],
          quantity: qty,
          ltp: ltp_bd,
          position_id: pos[:id]
        )
        book_inr_from_paper_close(res, row: nil, pair: pair, source: :flatten)
      end

      def coerce_ltp(ltp)
        return nil if ltp.nil?

        BigDecimal(ltp.to_s)
      rescue ArgumentError, TypeError
        nil
      end

      def book_inr_from_paper_close(result, row:, pair:, source:)
        return unless paper_broker_close_result?(result) && result[:ok]

        raw = result[:realized_pnl_usdt]
        if raw.nil?
          @logger&.warn("[paper] close ok but missing realized_pnl_usdt for #{pair} — booking 0 USDT")
        end

        usdt = raw.nil? ? BigDecimal('0') : BigDecimal(raw.to_s)
        inr = usdt * @fx.inr_per_usdt
        fill_s = paper_close_fill_price_for_event(result)
        @journal.add_daily_pnl_inr(inr)
        @journal.log_event(
          'paper_realized',
          position_id: row&.dig(:id) || result[:position_id],
          pair: pair,
          pnl_usdt: usdt.to_s('F'),
          pnl_inr: inr.to_s('F'),
          exit_price: fill_s,
          source: source.to_s
        )
        @logger&.info("[paper] PnL ~₹#{inr.to_s('F')} (#{usdt.to_s('F')} USDT) #{pair}")
      end

      def paper_broker_close_result?(result)
        result.is_a?(Hash) && result.key?(:ok)
      end

      # After paper close: aligns TUI/event log with whether the exchange close + INR booking ran.
      def summarize_paper_close_outcome(broker_res, exchange_attempted, skipped_no_ltp)
        return ['skipped_no_ltp', false] if skipped_no_ltp
        return ['journal_closed_no_exchange', false] unless exchange_attempted

        unless paper_broker_close_result?(broker_res)
          return ['closed', false]
        end

        return ['exchange_failed', false] unless broker_res[:ok]

        ['closed', true]
      end

      # Local {PaperBroker} needs an LTP for fill simulation. {GatewayPaperBroker} exits via the
      # paper exchange mark price and ignores this value.
      def paper_close_allowed?(exit_price)
        return true if exit_price
        return true if @broker.is_a?(CoindcxBot::Execution::GatewayPaperBroker)

        false
      end

      def paper_close_ltp(exit_price)
        return BigDecimal('0') if exit_price.nil?

        BigDecimal(exit_price.to_s)
      end

      def paper_close_fill_price_for_event(result)
        fp = result[:fill_price]
        return '0' if fp.nil?

        BigDecimal(fp.to_s).to_s('F')
      rescue ArgumentError, TypeError
        '0'
      end

      def sync_journal_entry_from_paper_fill(pair, journal_id)
        paper_pos = @broker.open_position_for(pair)
        return unless paper_pos && paper_pos[:entry_price]

        @journal.update_position_entry_price(journal_id, paper_pos[:entry_price])
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

      # Compute take-profit price at a configurable R-multiple from entry.
      def compute_take_profit(side, entry_price, stop_price)
        return nil if stop_price.nil? || entry_price.nil?

        risk_reward = BigDecimal(
          @config.paper_config.fetch(:take_profit_r_multiple, 3).to_s
        )
        risk = (entry_price - stop_price).abs
        return nil if risk <= 0

        case side.to_sym
        when :long
          entry_price + (risk * risk_reward)
        when :short
          entry_price - (risk * risk_reward)
        end
      end

    end
  end
end
