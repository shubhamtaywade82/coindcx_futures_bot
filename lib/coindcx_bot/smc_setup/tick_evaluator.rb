# frozen_string_literal: true

require 'bigdecimal'
require_relative 'states'
require_relative 'gatekeeper_brain'
require_relative '../strategy/signal'

module CoindcxBot
  module SmcSetup
    # Hot-path FSM: LTP vs zones + last closed-bar SMC flags. May call Coordinator when armed.
    class TickEvaluator
      MAX_STATE_HOPS = 8

      def initialize(config:, journal:, coordinator:, risk:, store:, logger:,
                     smc_configuration:, regime_sizer: nil, hmm_runtime: nil, setup_mutex_factory: nil)
        @config = config
        @journal = journal
        @coord = coordinator
        @risk = risk
        @store = store
        @logger = logger
        @smc_cfg = smc_configuration
        @regime_sizer = regime_sizer
        @hmm_runtime = hmm_runtime
        @mutex_for = setup_mutex_factory || ->(_setup_id) { Mutex.new }
        @consecutive = config.smc_setup_sweep_consecutive_ticks
      end

      def evaluate_pair!(pair:, ltp:, candles_exec:, stale:)
        bar = last_bar_result(candles_exec)
        bars_json = compact_bars_json(candles_exec, 10)
        @store.records_for_pair(pair).map(&:setup_id).uniq.each do |setup_id|
          mutex = @mutex_for.call(setup_id)
          mutex.synchronize do
            hops = 0
            loop do
              hops += 1
              break if hops > MAX_STATE_HOPS

              rec = @store.record_by_id(setup_id)
              break unless rec

              if invalidate_for_lifecycle!(rec, pair, ltp)
                break
              end

              if rec.state != States::ACTIVE && rec.trade_setup.expired?
                @logger&.info("[smc_setup] #{setup_id} expired at #{rec.trade_setup.expires_at}")
                rec.state = States::INVALIDATED
                @store.persist_record!(rec)
                @journal.log_event(
                  'smc_setup_invalidated',
                  rec.trade_setup.event_payload.merge(
                    reason: 'time_expired',
                    dedupe_key: "invalid|#{setup_id}|time_expired"
                  )
                )
                break
              end

              cont = run_step(
                rec,
                pair: pair,
                ltp: ltp,
                bar: bar,
                stale: stale,
                bars_json: bars_json,
                candles_exec: candles_exec
              )
              break unless cont
            end
          end
        end
      end

      private

      def invalidate_for_lifecycle!(rec, pair, ltp)
        return false unless @config.smc_setup_lifecycle_enabled?
        return false if States::TERMINAL.include?(rec.state)

        ts = rec.trade_setup
        if ltp
          p = BigDecimal(ltp.to_s)
          if ts.in_no_trade_zone?(p)
            rec.state = States::INVALIDATED
            @store.persist_record!(rec)
            @journal.log_event(
              'smc_setup_invalidated',
              ts.event_payload.merge(
                reason: 'no_trade_zone',
                ltp: p.to_f.to_s,
                dedupe_key: "invalid|#{rec.setup_id}|no_trade_zone"
              )
            )
            return true
          end
          if ts.breached_invalidation?(p)
            rec.state = States::INVALIDATED
            @store.persist_record!(rec)
            @journal.log_event(
              'smc_setup_invalidated',
              ts.event_payload.merge(
                reason: 'invalidation_level',
                ltp: p.to_f.to_s,
                dedupe_key: "invalid|#{rec.setup_id}|invalidation_level"
              )
            )
            return true
          end
        end

        false
      end

      def run_step(rec, pair:, ltp:, bar:, stale:, bars_json:, candles_exec:)
        case rec.state
        when States::PENDING_SWEEP
          step_pending_sweep(rec, ltp)
        when States::SWEEP_SEEN
          step_sweep_seen(rec, bar, bars_json, pair: pair, candles_exec: candles_exec)
        when States::AWAITING_CONFIRMATIONS
          step_awaiting_confirmations(rec, bar, bars_json, pair: pair, candles_exec: candles_exec)
        when States::ARMED_ENTRY
          step_armed_entry(rec, pair, ltp, stale)
          false
        when States::ACTIVE
          step_active(rec)
          false
        else
          false
        end
      end

      def step_pending_sweep(rec, ltp)
        return false if ltp.nil?

        p = BigDecimal(ltp.to_s)
        ts = rec.trade_setup
        in_sweep = in_zone?(p, ts.sweep_min, ts.sweep_max)
        streak = in_sweep ? rec.eval_state[:sweep_streak].to_i + 1 : 0
        rec.eval_state = rec.eval_state.merge(sweep_streak: streak)
        if streak < @consecutive
          @store.persist_record!(rec)
          return false
        end

        rec.state = States::SWEEP_SEEN
        rec.eval_state = rec.eval_state.merge(sweep_streak: 0)
        @store.persist_record!(rec)
        true
      end

      def step_sweep_seen(rec, bar, bars_json, pair:, candles_exec:)
        if rec.trade_setup.confirmations.empty?
          try_arm_entry(rec, bar, bars_json, pair: pair, candles_exec: candles_exec)
        else
          rec.state = States::AWAITING_CONFIRMATIONS
          @store.persist_record!(rec)
        end
        rec.state == States::ARMED_ENTRY
      end

      def step_awaiting_confirmations(rec, bar, bars_json, pair:, candles_exec:)
        return false unless bar

        dir = rec.trade_setup.direction
        ok = rec.trade_setup.confirmations.all? { |c| confirmation_satisfied?(bar, c, dir) }
        return false unless ok

        try_arm_entry(rec, bar, bars_json, pair: pair, candles_exec: candles_exec)
        rec.state == States::ARMED_ENTRY
      end

      def try_arm_entry(rec, bar, bars_json, pair:, candles_exec:)
        return unless hmm_allows_direction?(pair, rec)

        need_gate = rec.trade_setup.gatekeeper && @config.smc_setup_gatekeeper_enabled?
        if need_gate
          now = Time.now.to_f
          min_iv = @config.smc_setup_gatekeeper_min_interval_seconds
          last = rec.eval_state[:last_gate_ts].to_f
          if rec.eval_state[:gate_ok] == true && (now - last) < min_iv
            promote_armed!(rec, pair, gate_ok: 'cached')
            return
          end
          if (now - last) < min_iv && rec.eval_state[:gate_ok] != true
            return
          end

          gk = (@gatekeeper ||= GatekeeperBrain.new(config: @config, logger: @logger))
          ohlcv = gatekeeper_ohlcv_features(pair: pair, candles_exec: candles_exec, bar: bar, trade_setup: rec.trade_setup)
          approved = gk.approve?(rec: rec, bar: bar, bars_json: bars_json, ohlcv_features: ohlcv)
          rec.eval_state = rec.eval_state.merge(last_gate_ts: now, gate_ok: approved)
          @store.persist_record!(rec)
          return unless approved

          promote_armed!(rec, pair, gate_ok: 'approved')
          return
        end

        promote_armed!(rec, pair, gate_ok: 'no_gate')
      end

      def promote_armed!(rec, pair, gate_ok:)
        was = rec.state
        rec.state = States::ARMED_ENTRY
        @store.persist_record!(rec)
        return if was == States::ARMED_ENTRY

        @journal.log_event(
          'smc_setup_armed',
          rec.trade_setup.event_payload.merge(
            gate_ok: gate_ok.to_s,
            dedupe_key: "armed|#{rec.setup_id}"
          )
        )
      end

      # Reject arming when HMM reports a stable regime that conflicts with the trade direction.
      # +stable_state_for+ returns nil until the RegimeStateMachine has confirmed bars — we allow
      # arming in that pre-confirmation window rather than blocking indefinitely.
      def hmm_allows_direction?(pair, rec)
        return true unless @hmm_runtime.respond_to?(:stable_state_for)

        stable = @hmm_runtime.stable_state_for(pair)
        return true if stable.nil?

        label = stable[:label].to_s
        direction = rec.trade_setup.direction
        conflict =
          (direction == :long && %w[TREND_DN VOL_BEAR].include?(label)) ||
          (direction == :short && %w[TREND_UP VOL_BULL].include?(label))

        return true unless conflict

        @journal.log_event(
          'smc_setup_invalidated',
          rec.trade_setup.event_payload.merge(
            reason: "hmm_conflict:#{label}",
            dedupe_key: "invalid|#{rec.setup_id}|hmm"
          )
        )
        rec.state = States::INVALIDATED
        @store.persist_record!(rec)
        false
      end

      def step_armed_entry(rec, pair, ltp, stale)
        return if ltp.nil?

        unless @config.smc_setup_auto_execute?
          @logger&.info("[smc_setup] #{rec.setup_id} armed (auto_execute false — no order)") if trace?
          return
        end

        p = BigDecimal(ltp.to_s)
        ts = rec.trade_setup
        return unless in_zone?(p, ts.entry_min, ts.entry_max)

        if @journal.open_position_with_smc_setup?(rec.setup_id)
          rec.state = States::ACTIVE
          @store.persist_record!(rec)
          return
        end

        if stale
          @logger&.info("[smc_setup] #{rec.setup_id} entry skipped: stale_feed") if trace?
          return
        end

        if @risk.daily_loss_breached?
          @logger&.info("[smc_setup] #{rec.setup_id} entry skipped: daily_loss_limit") if trace?
          return
        end

        gate = @risk.allow_new_entry?(open_positions: @journal.open_positions, pair: pair)
        unless gate.first == :ok
          @logger&.info("[smc_setup] #{rec.setup_id} entry skipped: #{gate.last}") if trace?
          return
        end

        entry = p
        side = ts.long? ? :long : :short
        action = ts.long? ? :open_long : :open_short
        qty = @risk.size_quantity(entry_price: entry, stop_price: ts.sl, side: side)
        if @regime_sizer
          mult = @regime_sizer.multiplier_for(@journal)
          qty = (qty * mult).round(6, BigDecimal::ROUND_DOWN)
        end
        if qty.nil? || qty <= 0
          @logger&.info("[smc_setup] #{rec.setup_id} entry skipped: zero_quantity") if trace?
          return
        end

        sig = Strategy::Signal.new(
          action: action,
          pair: pair,
          side: side,
          stop_price: ts.sl,
          reason: 'smc_setup_entry',
          metadata: { smc_setup_id: ts.setup_id }
        )

        return if @journal.open_position_with_smc_setup?(rec.setup_id)

        @coord.apply(sig, quantity: qty, entry_price: entry)

        unless @journal.open_position_with_smc_setup?(rec.setup_id)
          @logger&.warn("[smc_setup] #{rec.setup_id} open not reflected in journal — staying armed") if trace?
          return
        end

        rec.state = States::ACTIVE
        @store.persist_record!(rec)
        @journal.log_event(
          'smc_setup_fired',
          ts.event_payload.merge(
            entry_price: entry.to_f.to_s,
            quantity: qty.to_f.to_s,
            dedupe_key: "fired|#{ts.setup_id}"
          )
        )
      end

      def step_active(rec)
        return if @journal.open_position_with_smc_setup?(rec.setup_id)

        rec.state = States::COMPLETED
        @store.persist_record!(rec)
        @store.reload!
      end

      def gatekeeper_ohlcv_features(pair:, candles_exec:, bar:, trade_setup:)
        return nil unless @config.smc_setup_gatekeeper_include_feature_packet?

        min = @config.smc_setup_gatekeeper_feature_min_candles
        exec = Array(candles_exec)
        return nil if exec.size < min

        rows = SmcConfluence::Candles.from_dto(exec)
        smc = CoindcxBot::TradingAi::SmcSnapshot.from_bar_result(bar)
        entry_mid = (trade_setup.entry_min + trade_setup.entry_max) / 2
        CoindcxBot::TradingAi::FeatureEnricher.call(
          candles: rows,
          smc: smc,
          dtw: {},
          history: [],
          entry: entry_mid.to_f,
          stop_loss: trade_setup.sl.to_f,
          targets: trade_setup.targets.map(&:to_f),
          symbol: pair,
          timeframe: nil,
          tz_offset_minutes: @config.smc_setup_gatekeeper_feature_tz_offset_minutes
        )
      end

      def compact_bars_json(candles_exec, n)
        Array(candles_exec).last(n).map do |c|
          t = c.respond_to?(:time) ? c.time : c[:time]
          {
            o: c.respond_to?(:open) ? c.open : c[:open],
            h: c.respond_to?(:high) ? c.high : c[:high],
            l: c.respond_to?(:low) ? c.low : c[:low],
            c: c.respond_to?(:close) ? c.close : c[:close],
            t: t
          }
        end
      end

      def trace?
        ENV['COINDCX_STRATEGY_SIGNALS'].to_s == '1' || @config.runtime[:log_strategy_signals].to_s == 'true'
      end

      def last_bar_result(candles_exec)
        exec = Array(candles_exec)
        return nil if exec.size < 20

        rows = SmcConfluence::Candles.from_dto(exec)
        series = SmcConfluence::Engine.run(rows, configuration: @smc_cfg)
        series.last
      end

      def in_zone?(price, zmin, zmax)
        lo = [zmin, zmax].min
        hi = [zmin, zmax].max
        price >= lo && price <= hi
      end

      def confirmation_satisfied?(bar, token, direction)
        dir = direction.to_sym
        case token.to_s.downcase
        when 'choch_bull', 'choch_up'
          bar.choch_bull
        when 'choch_bear', 'choch_down'
          bar.choch_bear
        when 'bos_bull', 'displacement_bull'
          bar.bos_bull
        when 'bos_bear', 'displacement_bear'
          bar.bos_bear
        when 'displacement'
          dir == :long ? bar.bos_bull : bar.bos_bear
        else
          false
        end
      end
    end
  end
end
