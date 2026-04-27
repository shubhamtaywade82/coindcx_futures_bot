# frozen_string_literal: true

require 'bigdecimal'
require 'json'
require 'logger'

require_relative '../display_ltp'
require_relative '../regime/tui_state'
require_relative '../regime/transition_meaning'
require_relative '../synthetic_l1'

module CoindcxBot
  module Core
    class Engine
      Snapshot = Struct.new(
        :pairs, :ticks, :positions, :paused, :kill_switch, :stale, :last_error, :daily_pnl,
        :running, :dry_run, :stale_tick_seconds, :paper_metrics,
        :capital_inr, :recent_events, :working_orders, :ws_last_tick_ms_ago,
        :strategy_last_by_pair, :regime, :smc_setup,
        :exchange_positions, :exchange_positions_error, :exchange_positions_fetched_at,
        :live_tui_metrics,
        keyword_init: true
      )

      COIN_DCX_HTTP_ATTRS_TO_MIRROR = %i[
        api_key api_secret logger public_base_url socket_base_url socket_io_connect_options
        open_timeout read_timeout max_retries retry_base_interval user_agent
        socket_io_backend_factory socket_reconnect_attempts socket_reconnect_interval
        socket_heartbeat_interval socket_liveness_timeout market_data_retry_budget
        private_read_retry_budget idempotent_order_retry_budget
        circuit_breaker_threshold circuit_breaker_cooldown
      ].freeze

      def initialize(config:, logger: nil, tick_store: nil, on_tick: nil, order_book_store: nil,
                     on_market_data: nil)
        @config = config
        @logger = logger || Logger.new($stdout)
        base_telegram_sink = CoindcxBot::Notifications::TelegramJournalSink.build_if_configured(config: config, logger: @logger)
        alert_policy = CoindcxBot::Alerts::TelegramPolicy.new(config)
        event_sink =
          if base_telegram_sink && config.alerts_filter_telegram?
            CoindcxBot::Alerts::FilteredEventSink.new(base_telegram_sink, alert_policy)
          else
            base_telegram_sink
          end
        @journal = Persistence::Journal.new(
          config.journal_path,
          event_sink: event_sink
        )
        @bus = EventBus.new
        @tick_store = tick_store
        @on_tick = on_tick
        @order_book_store = order_book_store
        @on_market_data = on_market_data
        @stale_seconds = config.runtime.fetch(:stale_tick_seconds, 45).to_i
        @stale_recovery_sleep = config.runtime.fetch(:stale_recovery_sleep_seconds, 5).to_f
        @tracker = PositionTracker.new(
          journal: @journal,
          stale_tick_seconds: @stale_seconds
        )
        @exposure = Risk::ExposureGuard.new(config: config)

        configure_coin_dcx
        @client = CoinDCX.client
        @order_account_client = order_account_rest_client(config)
        @fx = Fx::UsdtInrRate.new(client: @client, config: config, logger: @logger)
        @risk = Risk::Manager.new(config: config, journal: @journal, exposure_guard: @exposure, fx: @fx)
        @strategy = build_strategy(config.strategy)

        @md = Gateways::MarketDataGateway.new(
          client: @client,
          margin_currency_short_name: config.margin_currency_short_name
        )
        @orders = Gateways::OrderGateway.new(
          client: @order_account_client,
          order_defaults: config.execution.fetch(:order_defaults, {})
        )
        @account = Gateways::AccountGateway.new(client: @order_account_client)
        @ws = Gateways::WsGateway.new(client: @client, logger: @logger)
        @broker = build_broker(config)

        @order_tracker = Execution::OrderTracker.new(journal: @journal, logger: @logger)
        @ws_fill_handler = Execution::WsFillHandler.new(order_tracker: @order_tracker, logger: @logger)

        @coord = Execution::Coordinator.new(
          broker: @broker,
          journal: @journal,
          config: config,
          exposure_guard: @exposure,
          logger: @logger,
          fx: @fx,
          order_tracker: @order_tracker
        )

        @candles_htf = {}
        @candles_exec = {}
        @stop = false
        @last_error = nil
        @htf_res = config.strategy.fetch(:higher_timeframe_resolution, '1h').to_s
        @exec_res = config.strategy.fetch(:execution_resolution, '15m').to_s
        @refresh = config.runtime.fetch(:refresh_candles_seconds, 60).to_f
        @lookback = config.runtime.fetch(:candle_lookback, 120).to_i
        @ws_tick_at = {}
        @last_strategy_by_pair = {}
        @analysis_last_sig_fingerprint = {}
        @analysis_strategy_candidate = {}
        @analysis_strategy_candidate_count = Hash.new(0)
        @analysis_last_hmm_state = {}
        @analysis_price_rule_zone = {}
        @price_cross_cooldown = Alerts::PriceCrossCooldown.new
        @regime_ai_mutex = Mutex.new
        @regime_ai_state = { updated_at: nil, payload: nil, error: nil }
        @regime_ai_brain = nil
        @hmm_runtime = Regime::HmmRuntime.new(config: @config, logger: @logger) if @config.regime_hmm_enabled?
        @ml_runtime = Regime::MlRuntime.new(config: @config, logger: @logger) if @config.regime_ml_enabled?
        @regime_sizer = Risk::RegimeSizer.new(@config) if @config.regime_risk_enabled?
        @margin_sim = Risk::MarginSimulator.new(config: @config, logger: @logger)
        @daily_loss_flatten_warned = false
        @engine_loop_crashed = false
        @tui_focus_pair = nil # TUI sets each frame; regime strip + regime AI use it
        @exchange_positions_tui_mutex = Mutex.new
        @exchange_positions_tui = { rows: [], error: nil, fetched_at: nil }
        @futures_wallet_tui_mutex = Mutex.new
        @futures_wallet_tui = {
          wallet_amount: nil,
          wallet_currency: nil,
          wallet_available: nil,
          wallet_locked: nil,
          wallet_cross_order_margin: nil,
          wallet_cross_user_margin: nil,
          error: nil,
          fetched_at: nil
        }
        @smc_setup_store = nil
        @smc_setup_eval = nil
        @smc_setup_planner = nil
        @smc_setup_planner_state = { updated_at: nil, error: nil }
        @smc_setup_planner_mutex = Mutex.new
        @smc_setup_planner_running = false
        @regime_ai_running = false
        @regime_ai_thread_mutex = Mutex.new
        @smc_setup_mutexes = Hash.new { |h, k| h[k] = Mutex.new }
        init_smc_setup_stack! if @config.smc_setup_enabled?

        @stop_breach_queue = {}
        @stop_breach_mutex = Mutex.new

        @runtime_reconcile_at    = nil
        @runtime_reconcile_mutex = Mutex.new

        @bus.subscribe(:tick) do |tick|
          @ws_tick_at[tick.pair] = Time.now
          @tracker.record_tick(tick)
          forward_tick_to_store(tick)
          @logger&.info("[ws] tick #{tick.pair} #{tick.price}") if ENV['COINDCX_WS_TRACE'].to_s == '1'
          check_and_queue_stop_breach(tick) if !@config.dry_run? && @config.exit_on_hard_stop?
          @on_tick&.call(tick)
        end

        @ws_shutdown_timeout = config.runtime.fetch(:ws_shutdown_join_seconds, 45).to_f
        @strategy_signal_trace = strategy_signal_trace_enabled?(config)
      end

      attr_reader :config, :logger, :journal, :broker
      attr_accessor :tui_focus_pair

      def inr_per_usdt
        @fx.inr_per_usdt
      end

      # Wall-clock time of the last **WebSocket** tick for this pair (not REST candle mirrors).
      def last_ws_tick_at(pair)
        @ws_tick_at[pair]
      end

      # True when no recent **WebSocket** tick for this pair (entry gating). TUI uses this for [STALE];
      # LTP "AGE" uses `TickStore#updated_at` (WS ticks + optional fast REST TUI poll).
      def ws_feed_stale?(pair)
        at = @ws_tick_at[pair]
        return true unless at

        Time.now - at > @stale_seconds
      end

      def snapshot
        ticks = @config.pairs.to_h do |p|
          tick_at = @tracker.last_tick_at(p)
          h = { price: @tracker.ltp(p), at: tick_at }
          if @tick_store
            mk = @tick_store.snapshot[p]&.mark
            h[:mark] = mk unless mk.nil?
          end
          [p, h]
        end
        stale = @config.pairs.any? { |p| ws_feed_stale?(p) }

        pm = @broker.paper? ? paper_snapshot_metrics(ticks) : {}

        ex = exchange_positions_tui_for_snapshot
        live_metrics = build_live_tui_metrics(ex[:rows], ticks)
        Snapshot.new(
          pairs: @config.pairs,
          ticks: ticks,
          positions: @journal.open_positions,
          paused: @journal.paused?,
          kill_switch: @journal.kill_switch?,
          stale: stale,
          last_error: @last_error,
          daily_pnl: @journal.daily_pnl_inr,
          running: !@stop && !@engine_loop_crashed,
          dry_run: @config.dry_run?,
          stale_tick_seconds: @stale_seconds,
          paper_metrics: pm,
          capital_inr: snapshot_capital_inr,
          recent_events: snapshot_recent_events,
          working_orders: @broker.tui_working_orders,
          ws_last_tick_ms_ago: snapshot_ws_last_tick_ms_ago,
          strategy_last_by_pair: @last_strategy_by_pair.dup,
          regime: regime_snapshot_for_tui,
          smc_setup: smc_setup_overlay_for_tui,
          exchange_positions: ex[:rows],
          exchange_positions_error: ex[:error],
          exchange_positions_fetched_at: ex[:fetched_at],
          live_tui_metrics: live_metrics
        )
      end

      def request_stop!
        @stop = true
      end

      # Called from the TUI when the main engine thread terminates with an error (after `run` re-raises).
      def engine_loop_failed!(message)
        @engine_loop_crashed = true
        @last_error = message.to_s
        @logger&.error("[engine] loop terminated: #{message}")
      end

      def engine_loop_crashed?
        @engine_loop_crashed
      end

      def pause!
        @journal.set_paused(true)
      end

      def resume!
        @journal.set_paused(false)
      end

      def kill_switch_on!
        @journal.set_kill_switch(true)
      end

      def kill_switch_off!
        @journal.set_kill_switch(false)
      end

      def flatten_all!
        ltps = flatten_ltps_for_pairs
        @coord.flatten_all(@config.pairs, ltps: ltps)
      end

      def run
        if !@config.dry_run? && !@config.place_orders?
          @logger.warn(
            '[engine] LIVE-OBSERVE mode: strategy signals evaluated, journal updated, ' \
            'NO orders placed (runtime.place_orders: false / PLACE_ORDER=0)'
          )
        end

        # SIGHUP: graceful stop so the process manager (systemd, supervisord) can restart
        # with fresh config. Only minimal work is safe inside a signal handler.
        @sighup_received = false
        Signal.trap('HUP') { @sighup_received = true; @stop = true }

        # Reconcile journal against broker state before the first tick cycle.
        @coord.reconcile_paper_state!
        @coord.reconcile_live_state!

        ws_thread = Thread.new { run_ws_loop }
        loop do
          break if @stop

          if @sighup_received
            @logger.info('[engine] SIGHUP received — stopping for graceful restart')
            break
          end

          tick_cycle
          break if @stop

          interruptible_sleep(sleep_seconds_after_tick_cycle)
        end
        finished = ws_thread.join(@ws_shutdown_timeout)
        @logger.warn('WebSocket thread did not finish within ws_shutdown_join_seconds') unless finished
        @ws.disconnect
      rescue StandardError => e
        @last_error = e.message
        @logger.error(e.full_message)
        raise
      end

      private

      def regime_snapshot_for_tui
        base = Regime::TuiState.build(@config)
        merged = base.dup
        if @hmm_runtime
          merged = merged.merge(@hmm_runtime.tui_overlay(primary_pair: @tui_focus_pair))
        end
        return merged unless @config.regime_ai_enabled?

        snap = @regime_ai_mutex.synchronize { @regime_ai_state.dup }
        merged.merge(Regime::AiBrain.overlay_from_state(snap))
      end

      # Launches the regime AI analysis in a background thread to avoid blocking tick_cycle.
      def refresh_regime_ai_if_due
        return unless @config.regime_ai_enabled?

        now = Time.now
        @regime_ai_mutex.synchronize do
          last = @regime_ai_state[:updated_at]
          return if last && (now - last) < @config.regime_ai_min_interval_seconds
        end

        already_running = @regime_ai_thread_mutex.synchronize do
          return if @regime_ai_running
          @regime_ai_running = true
          false
        end
        return if already_running

        ctx = build_regime_ai_context
        if @config.regime_ai_include_hmm_context? && @hmm_runtime
          ctx[:hmm] = @hmm_runtime.hmm_context_for_ai
        end
        if ctx[:pairs].empty?
          @regime_ai_thread_mutex.synchronize { @regime_ai_running = false }
          return
        end

        Thread.new do
          Thread.current.name = 'regime_ai'
          run_regime_ai_sync(ctx, now)
        ensure
          @regime_ai_thread_mutex.synchronize { @regime_ai_running = false }
        end
      end

      def run_regime_ai_sync(ctx, started_at)
        prev_payload = @regime_ai_mutex.synchronize { @regime_ai_state[:payload] }
        brain = (@regime_ai_brain ||= Regime::AiBrain.new(config: @config, logger: @logger))
        res = brain.analyze!(ctx)
        @regime_ai_mutex.synchronize do
          @regime_ai_state[:updated_at] = started_at
          if res.ok && res.payload
            @regime_ai_state[:payload] = res.payload
            @regime_ai_state[:error] = nil
          else
            @regime_ai_state[:payload] = nil
            @regime_ai_state[:error] = res.error_message
          end
        end
        maybe_log_regime_ai_transition!(prev_payload, res.payload) if res.ok && res.payload.is_a?(Hash)
      rescue StandardError => e
        @logger&.warn("[regime_ai] #{e.class}: #{e.message}")
        @regime_ai_mutex.synchronize { @regime_ai_state[:error] = e.message }
      end

      def maybe_flatten_on_daily_loss_breach
        return unless @config.flatten_on_daily_loss_breach?
        return unless @risk.daily_loss_breached?
        return if @journal.open_positions.empty?
        return if @journal.paused? || @journal.kill_switch?

        if !@config.dry_run? && !@config.place_orders?
          unless @daily_loss_flatten_warned
            @logger&.warn(
              '[engine] Daily loss limit breached — flatten skipped: live order placement disabled ' \
              '(runtime.place_orders / PLACE_ORDER)'
            )
            @daily_loss_flatten_warned = true
          end
          @journal.set_paused(true) if @config.pause_after_daily_loss_flatten?
          return
        end

        unless @daily_loss_flatten_warned
          @logger&.warn('[engine] Daily loss limit breached — flattening all positions (risk.flatten_on_daily_loss_breach)')
          @daily_loss_flatten_warned = true
        end
        @coord.flatten_all(@config.pairs, ltps: flatten_ltps_for_pairs)
        @journal.set_paused(true) if @config.pause_after_daily_loss_flatten?
      rescue StandardError => e
        @logger&.error("[engine] Daily loss flatten failed: #{e.message}")
        @journal.set_paused(true) if @config.pause_after_daily_loss_flatten?
      end

      def build_regime_ai_context
        max_pairs = @config.regime_ai_max_pairs
        n = @config.regime_ai_bars_per_pair
        ordered = @config.pairs.map(&:to_s)
        fp = @tui_focus_pair.to_s.strip
        ordered = [fp] + ordered.reject { |x| x == fp } if fp && ordered.include?(fp)
        pairs = ordered.first(max_pairs)
        features_by_pair = build_regime_ai_features_by_pair(pairs)
        omit_raw = @config.regime_ai_omit_raw_bars_when_feature_packet?
        candles_by_pair =
          pairs.to_h do |p|
            arr = Array(@candles_exec[p]).last(n)
            rows = arr.map do |c|
              { o: c.open, h: c.high, l: c.low, c: c.close, v: c.volume }
            end
            rows = [] if omit_raw && features_by_pair.key?(p)
            [p, rows]
          end

        pos = if @config.tui_exchange_mirror? && !@config.dry_run?
                build_mirrored_positions_for_ai
              else
                @journal.open_positions
              end

        {
          pairs: pairs,
          candles_by_pair: candles_by_pair,
          features_by_pair: features_by_pair,
          positions: pos,
          exec_resolution: @exec_res,
          htf_resolution: @htf_res
        }
      end

      def build_mirrored_positions_for_ai
        idx = {}
        snap_rows = @exchange_positions_tui_mutex.synchronize { @exchange_positions_tui[:rows] || [] }
        snap_rows.each do |row|
          next unless CoindcxBot::Tui::LiveAccountMirror.row_open?(row)

          pair = CoindcxBot::Tui::LiveAccountMirror.normalize_bot_pair(row)
          next if pair.empty?

          pseudo = CoindcxBot::Tui::LiveAccountMirror.pseudo_journal_from_exchange(row)
          idx[pair] = pseudo if pseudo
        end
        idx.values
      end

      def build_regime_ai_features_by_pair(pairs)
        return {} unless @config.regime_ai_include_feature_packet?

        min = @config.regime_ai_feature_min_candles
        tz = @config.regime_ai_feature_tz_offset_minutes
        smc_cfg = SmcConfluence::Configuration.from_hash(@config.strategy[:smc_confluence] || {})
        out = {}
        pairs.each do |p|
          exec = Array(@candles_exec[p])
          next if exec.size < min

          rows = SmcConfluence::Candles.from_dto(exec)
          bar = SmcConfluence::Engine.run(rows, configuration: smc_cfg).last
          smc = CoindcxBot::TradingAi::SmcSnapshot.from_bar_result(bar)
          out[p] = CoindcxBot::TradingAi::FeatureEnricher.call(
            candles: rows,
            smc: smc,
            dtw: {},
            history: [],
            entry: nil,
            stop_loss: nil,
            targets: [],
            symbol: p,
            timeframe: @exec_res,
            tz_offset_minutes: tz
          )
        end
        out
      end

      def regime_hint_for(pair)
        hmm_tier = nil
        hmm_state = nil
        if @hmm_runtime && (st = @hmm_runtime.state_for(pair))
          hmm_state = st
          hmm_tier = Regime::Allocation.vol_tier(st.vol_rank, st.vol_rank_total)
        end

        ml_hash = ml_regime_hint_slice(pair)

        return nil if hmm_tier.nil? && ml_hash.nil?

        prec = @config.regime_ml_tier_precedence
        tier = if prec == 'ml_first'
                 (ml_hash && ml_hash[:tier]) || hmm_tier
               else
                 hmm_tier || (ml_hash && ml_hash[:tier])
               end

        out = { tier: tier, state: hmm_state }
        out[:ml] = ml_hash if ml_hash
        out
      end

      def ml_regime_hint_slice(pair)
        return nil unless @ml_runtime

        ml = @ml_runtime.state_for(pair)
        return nil unless ml

        {
          label: ml.label,
          class_index: ml.class_index,
          probability: ml.probability,
          tier: ml.tier,
          raw_label: ml.raw_label,
          raw_class_index: ml.raw_class_index,
          raw_max_probability: ml.raw_max_probability
        }
      end

      def init_smc_setup_stack!
        @smc_setup_store = SmcSetup::TradeSetupStore.new(
          journal: @journal,
          max_active_setups_per_pair: @config.smc_setup_max_active_setups_per_pair
        )
        @smc_setup_store.reload!
        smc_cfg = SmcConfluence::Configuration.from_hash(@config.strategy[:smc_confluence] || {})
        @smc_setup_eval = SmcSetup::TickEvaluator.new(
          config: @config,
          journal: @journal,
          coordinator: @coord,
          risk: @risk,
          store: @smc_setup_store,
          logger: @logger,
          smc_configuration: smc_cfg,
          regime_sizer: @regime_sizer,
          hmm_runtime: @hmm_runtime,
          setup_mutex_factory: ->(id) { @smc_setup_mutexes[id] }
        )
      end

      def run_smc_setup_evaluator!
        return unless @smc_setup_eval && @smc_setup_store

        @config.pairs.each do |pair|
          next if @journal.paused? || @journal.kill_switch?

          stale = ws_feed_stale?(pair)
          ltp = @tracker.ltp(pair)
          exec = @candles_exec[pair] || []
          @smc_setup_eval.evaluate_pair!(pair: pair, ltp: ltp, candles_exec: exec, stale: stale)
        end
      end

      # Launches the SMC planner in a background thread to avoid blocking tick_cycle.
      # The planner calls Ollama (timeout up to 90s) — running it inline would stall
      # SL/TP fills and signal generation for the entire duration.
      def refresh_smc_setup_planner_if_due
        return unless @config.smc_setup_planner_enabled?
        return unless @smc_setup_store

        now = Time.now
        last = @smc_setup_planner_state[:updated_at]
        return if last && (now - last) < @config.smc_setup_planner_interval_seconds

        already_running = @smc_setup_planner_mutex.synchronize do
          return if @smc_setup_planner_running
          @smc_setup_planner_running = true
          false
        end
        return if already_running

        ctx = build_smc_planner_context
        if ctx[:pairs].empty?
          @smc_setup_planner_mutex.synchronize { @smc_setup_planner_running = false }
          return
        end

        Thread.new do
          Thread.current.name = 'smc_planner'
          run_smc_planner_sync(ctx, now)
        ensure
          @smc_setup_planner_mutex.synchronize { @smc_setup_planner_running = false }
        end
      end

      def run_smc_planner_sync(ctx, started_at)
        brain = (@smc_setup_planner ||= SmcSetup::PlannerBrain.new(config: @config, logger: @logger))
        res = brain.plan!(ctx)
        @smc_setup_planner_state[:updated_at] = started_at
        if res.ok && res.payload
          begin
            @smc_setup_store.upsert_from_hash!(
              res.payload,
              reset_state: @config.smc_setup_planner_reset_state?
            )
            sid = res.payload[:setup_id] || res.payload['setup_id']
            pair = res.payload[:pair] || res.payload['pair']
            @logger&.info("[smc_setup:planner] upserted setup_id=#{sid} pair=#{pair} (Ollama → TradeSetup store)")
            rec = @smc_setup_store.record_by_id(sid)
            if rec&.trade_setup
              if reject_setup_for_price_drift!(rec, pair)
                # rejected & invalidated — do not emit identified
              else
                @journal.log_event(
                  'smc_setup_identified',
                  rec.trade_setup.event_payload.merge(dedupe_key: "identified|#{sid}")
                )
              end
            end
            @smc_setup_planner_state[:error] = nil
          rescue SmcSetup::Validator::ValidationError => e
            @smc_setup_planner_state[:error] = e.message
          end
        else
          @smc_setup_planner_state[:error] = res.error_message
        end
      rescue StandardError => e
        @logger&.warn("[smc_setup:planner] #{e.class}: #{e.message}")
        @smc_setup_planner_state[:error] = e.message
      end

      # Returns true when the setup was rejected for being too far from the current LTP.
      def reject_setup_for_price_drift!(rec, pair)
        ts = rec.trade_setup
        ltp = @tracker.ltp(pair)
        return false if ltp.nil?

        ltp_f = ltp.to_f
        return false if ltp_f <= 0

        max_pct = @config.smc_setup_planner_max_price_deviation_pct
        prices = [ts.entry_min, ts.entry_max, ts.sweep_min, ts.sweep_max, ts.sl, *ts.targets].map(&:to_f)
        worst = prices.map { |p| ((p - ltp_f).abs / ltp_f * 100.0) }.max
        return false if worst <= max_pct

        rec.state = SmcSetup::States::INVALIDATED
        @smc_setup_store.persist_record!(rec)
        @journal.log_event(
          'smc_setup_invalidated',
          ts.event_payload.merge(
            reason: format('price_drift:%.1f%%>%.1f%%(ltp=%s)', worst, max_pct, ltp_f),
            ltp: ltp_f.to_s,
            dedupe_key: "invalid|#{rec.setup_id}|price_drift"
          )
        )
        @logger&.warn(
          "[smc_setup:planner] rejected #{rec.setup_id} pair=#{pair} drift=#{worst.round(1)}% > #{max_pct}% (ltp=#{ltp_f})"
        )
        true
      end

      def build_smc_planner_context
        pairs = @config.pairs
        candles_full = pairs.to_h { |p| [p, Array(@candles_exec[p])] }
        ltps = pairs.to_h { |p| [p, @tracker.ltp(p)] }
        SmcSetup::PlannerContext.build(
          pairs: pairs,
          candles_by_pair: candles_full,
          ltps_by_pair: ltps,
          open_count: @journal.open_positions.size,
          exec_resolution: @exec_res,
          htf_resolution: @htf_res,
          strategy_cfg: @config.strategy,
          config: @config
        )
      end

      def smc_setup_skip_strategy_entries?(pair)
        return false unless @config.smc_setup_disable_strategy_entries?
        return false unless @smc_setup_store
        return false if @tracker.open_position_for(pair)

        @smc_setup_store.pair_has_actionable?(pair)
      end

      def smc_setup_overlay_for_tui
        return SmcSetup::TuiOverlay::DISABLED unless @config.smc_setup_enabled?

        st = @smc_setup_planner_state
        rows = []
        if @smc_setup_store
          @config.pairs.each do |p|
            @smc_setup_store.records_for_pair(p).each do |rec|
              rows << {
                setup_id: rec.setup_id,
                pair: rec.pair,
                state: rec.state,
                direction: rec.trade_setup.direction.to_s,
                gatekeeper: rec.trade_setup.gatekeeper
              }
            end
          end
        end

        err = st[:error].to_s
        err = "#{err[0, 70]}…" if err.length > 71

        {
          enabled: true,
          planner_enabled: @config.smc_setup_planner_enabled?,
          gatekeeper_enabled: @config.smc_setup_gatekeeper_enabled?,
          auto_execute: @config.smc_setup_auto_execute?,
          planner_last_at: st[:updated_at],
          planner_error: err,
          planner_interval_s: @config.smc_setup_planner_interval_seconds,
          active_count: rows.size,
          active_setups: rows
        }
      end

      def snapshot_capital_inr
        v = @config.raw[:capital_inr] || @config.raw['capital_inr']
        return nil if v.nil? || v.to_s.strip.empty?

        BigDecimal(v.to_s)
      rescue ArgumentError, TypeError
        nil
      end

      def snapshot_recent_events(limit = 12)
        rows = @journal.recent_events(limit).to_a
        rows.reverse.map { |r| normalize_event_row(r) }
      end

      def normalize_event_row(r)
        ts = r['ts'] || r[:ts]
        type = (r['type'] || r[:type]).to_s
        raw = r['payload'] || r[:payload] || '{}'
        payload =
          begin
            JSON.parse(raw.to_s, symbolize_names: true)
          rescue JSON::ParserError
            {}
          end
        { ts: ts.to_i, type: type, payload: payload }
      end

      def snapshot_ws_last_tick_ms_ago
        times = @config.pairs.filter_map { |p| @ws_tick_at[p] }
        return nil if times.empty?

        ((Time.now - times.max) * 1000).round
      end

      def strategy_signal_trace_enabled?(config)
        return true if ENV['COINDCX_STRATEGY_SIGNALS'].to_s == '1'

        !!config.runtime[:log_strategy_signals]
      end

      def log_strategy_signal(pair, sig)
        @logger&.info("[strategy] #{pair} #{sig.action} reason=#{sig.reason}")
      end

      def flatten_ltps_for_pairs
        @config.pairs.to_h do |p|
          ltp = @tracker.ltp(p)
          ltp ||= @candles_exec[p]&.last&.close
          [p, ltp]
        end
      end

      def run_paper_process_tick
        @config.pairs.each do |pair|
          ltp = @tracker.ltp(pair)
          next unless ltp

          candle = (@candles_exec[pair] || []).last
          high = candle&.high
          low = candle&.low
          results = @broker.process_tick(
            pair: pair,
            ltp: ltp,
            high: high,
            low: low,
            candles: @candles_exec[pair]
          )

          # Sync broker-driven exits (SL/TP fills) back to journal + PnL
          results.each do |r|
            next unless r[:kind] == :exit

            @coord.handle_broker_exit(
              pair: r[:pair],
              realized_pnl_usdt: r[:realized_pnl_usdt],
              fill_price: r[:fill_price],
              position_id: r[:position_id],
              trigger: r[:trigger]
            )
          end
        end
      end

      def build_broker(config)
        if config.dry_run? && config.paper_exchange_enabled?
          base = config.paper_exchange_api_base
          raise CoindcxBot::Config::ConfigurationError, 'paper_exchange.api_base_url is required when paper_exchange.enabled' if base.empty?

          Execution::GatewayPaperBroker.new(
            order_gateway: @orders,
            account_gateway: @account,
            journal: @journal,
            config: config,
            exposure_guard: @exposure,
            logger: @logger,
            tick_base_url: base,
            tick_path: config.paper_exchange_tick_path
          )
        elsif config.dry_run?
          paper_cfg = config.raw.fetch(:paper, {})
          slippage = paper_cfg.fetch(:slippage_bps, 5)
          fee = paper_cfg.fetch(:fee_bps, 4)
          funding = paper_cfg.fetch(:funding_rate_bps, 1)
          db_path = File.expand_path(
            paper_cfg.fetch(:db_path, './data/paper_trading.sqlite3'),
            Dir.pwd
          )

          fill_engine = Execution::FillEngine.new(slippage_bps: slippage, fee_bps: fee)
          store = Persistence::PaperStore.new(db_path)

          Execution::PaperBroker.new(
            store: store,
            fill_engine: fill_engine,
            logger: @logger,
            funding_rate_bps: funding,
            trail_config: config.strategy
          )
        else
          Execution::LiveBroker.new(
            order_gateway: @orders,
            account_gateway: @account,
            journal: @journal,
            config: config,
            exposure_guard: @exposure,
            logger: @logger
          )
        end
      end

      def paper_snapshot_metrics(ticks)
        store_snap = @tick_store ? @tick_store.snapshot : {}
        ltp_map = DisplayLtp.merge_prices_by_pair(
          @config.pairs,
          tick_store_snapshot: store_snap,
          tracker_tick_hash: ticks
        )
        base = @broker.metrics
        base[:total_realized_pnl] = @journal.sum_paper_realized_pnl_usdt if base[:total_realized_pnl].nil?
        base[:unrealized_pnl] = @broker.unrealized_pnl(ltp_map)

        # Record periodic equity snapshot for curve analysis
        @broker.record_snapshot(ltp_map) if @broker.respond_to?(:record_snapshot)

        base
      end

      def build_strategy(strategy_cfg)
        name = (strategy_cfg[:name] || 'trend_continuation').to_s
        case name
        when 'meta_first_win'
          Strategy::MetaFirstWin.new(strategy_cfg.transform_keys(&:to_sym), journal: @journal)
        when 'regime_vol_tier'
          merged = @config.regime_strategy_section.merge(strategy_cfg.transform_keys(&:to_sym))
          inner = build_inner_strategy_for_regime_wrapper(strategy_cfg)
          Strategy::RegimeVolTier.new(merged, inner: inner)
        when 'supertrend_profit'
          Strategy::SupertrendProfit.new(strategy_cfg)
        when 'smc_confluence'
          Strategy::SmcConfluence.new(strategy_cfg)
        else
          Strategy::TrendContinuation.new(strategy_cfg)
        end
      end

      def build_inner_strategy_for_regime_wrapper(strategy_cfg)
        inner_name = (strategy_cfg[:inner_strategy] || 'trend_continuation').to_s
        case inner_name
        when 'supertrend_profit'
          Strategy::SupertrendProfit.new(strategy_cfg)
        when 'smc_confluence'
          Strategy::SmcConfluence.new(strategy_cfg)
        else
          Strategy::TrendContinuation.new(strategy_cfg)
        end
      end

      def forward_tick_to_store(tick)
        return unless @tick_store

        bid, ask = tick_store_bid_ask(tick)
        @tick_store.update(
          symbol: tick.pair,
          ltp: tick.price,
          change_pct: tick.change_pct,
          updated_at: tick.received_at,
          bid: bid,
          ask: ask,
          mark: tick.mark_price
        )
      end

      def interruptible_sleep(total_seconds)
        deadline = Time.now + total_seconds
        until @stop || Time.now >= deadline
          sleep [deadline - Time.now, 1].min
        end
      end

      def mirror_tracker_into_tick_store
        return unless @tick_store

        @config.pairs.each do |pair|
          t = @tracker.last_tick(pair)
          next unless t

          # TUI `LtpRestPoller` refreshes `TickStore` on a short interval using public REST quotes.
          # Without this guard, each engine `tick_cycle` would overwrite `updated_at` with the
          # tracker's `received_at` (last WS or candle mirror), making AGE look ~30–60s stale and
          # hiding REST-driven LTP movement even while the footer shows a fast REST poll interval.
          existing = @tick_store.snapshot[pair]
          next if existing && existing.updated_at > t.received_at

          bid, ask = tick_store_bid_ask(t)
          @tick_store.update(
            symbol: pair,
            ltp: t.price,
            change_pct: t.change_pct,
            updated_at: t.received_at,
            bid: bid,
            ask: ask,
            mark: t.mark_price
          )
        end
      end

      def tick_store_bid_ask(tick)
        return [nil, nil] unless tick

        if l1_book_usable?(tick.bid, tick.ask)
          [tick.bid, tick.ask]
        else
          SyntheticL1.quote_from_mid_as_float(tick.price)
        end
      end

      def l1_book_usable?(bid, ask)
        return false if bid.nil? || ask.nil?

        b = BigDecimal(bid.to_s)
        a = BigDecimal(ask.to_s)
        b.positive? && a.positive? && a > b
      rescue ArgumentError, TypeError
        false
      end

      def configure_coin_dcx
        CoinDCX.configure do |c|
          c.api_key = ENV['COINDCX_API_KEY'].to_s.strip
          c.api_secret = ENV['COINDCX_API_SECRET'].to_s.strip
          c.logger = @logger

          # Gateway paper mode must NOT point the global REST client at the local paper exchange:
          # market data (candles, RT quotes) and FX still need production (or public) CoinDCX hosts.
          # Orders/positions use +order_account_rest_client+ (separate client) instead.

          url = ENV['COINDCX_SOCKET_BASE_URL'].to_s.strip
          c.socket_base_url = url unless url.empty?

          # Default backend (socket.io-client-simple) matches CoinDCX Engine.IO v3 only; forcing EIO 4
          # breaks the handshake. Leave gem default unless COINDCX_SOCKET_EIO is set explicitly.
          if c.respond_to?(:socket_io_connect_options=)
            eio = ENV['COINDCX_SOCKET_EIO'].to_s.strip
            c.socket_io_connect_options = { EIO: Integer(eio) } unless eio.empty?
          end
        end
      end

      # Futures REST for signed order + position calls. Stays on production +api.coindcx.com+ unless
      # +paper_exchange.enabled+, in which case a dedicated client targets +paper_exchange.api_base_url+.
      def order_account_rest_client(config)
        return @client unless config.dry_run? && config.paper_exchange_enabled?

        paper_rest_client_for_exchange(config.paper_exchange_api_base)
      end

      def paper_rest_client_for_exchange(base_url)
        base = base_url.to_s.strip
        if base.empty?
          raise CoindcxBot::Config::ConfigurationError,
                'paper_exchange.api_base_url is required when paper_exchange.enabled'
        end

        main = CoinDCX.configuration
        paper_cfg = CoinDCX::Configuration.new
        copy_shared_coin_dcx_http_settings!(from: main, to: paper_cfg)
        paper_cfg.api_base_url = base.chomp('/')
        CoinDCX::Client.new(configuration: paper_cfg)
      end

      def copy_shared_coin_dcx_http_settings!(from:, to:)
        COIN_DCX_HTTP_ATTRS_TO_MIRROR.each do |attr|
          to.send("#{attr}=", from.send(attr))
        end
        to.endpoint_rate_limits = from.endpoint_rate_limits.transform_values(&:dup)
      end

      def order_book_ltp_hint(pair)
        row = @tick_store&.snapshot&.dig(pair)
        if row&.ltp&.to_f&.positive?
          return row.ltp
        end

        px = @tracker.ltp(pair)
        return nil if px.nil?

        bd = BigDecimal(px.to_s)
        bd.positive? ? bd.to_f : nil
      rescue ArgumentError, TypeError
        nil
      end

      # Outer reconnect loop: on an unexpected WS session end, wait with exponential backoff
      # and restart subscriptions. Caps at ws_reconnect_attempts (0 = unlimited retries).
      def run_ws_loop
        max_attempts = @config.ws_reconnect_attempts
        base_delay   = @config.ws_reconnect_base_seconds
        attempt      = 0

        until @stop
          run_ws_once
          break if @stop

          attempt += 1
          if max_attempts > 0 && attempt >= max_attempts
            @logger.error("[ws] max reconnect attempts (#{max_attempts}) reached — WS feed offline")
            @engine_loop_crashed = true
            break
          end

          delay = [base_delay * (2**(attempt - 1)), 60.0].min
          @logger.warn("[ws] session ended — reconnecting in #{delay.round(1)}s (attempt #{attempt})")
          interruptible_sleep(delay)
        end
      rescue StandardError => e
        @last_error = e.message
        @logger.error("[ws] fatal: #{e.full_message}")
      end

      def run_ws_once
        conn = @ws.connect
        unless conn.ok?
          @last_error = "ws connect: #{conn.message}"
          return
        end

        @config.pairs.each do |pair|
          sub = @ws.subscribe_futures_prices(instrument: pair) { |tick| @bus.publish(:tick, tick) }
          @last_error = "ws sub #{pair}: #{sub.message}" if sub.failure?
        end

        rt = @ws.subscribe_futures_current_prices_rt(pairs: @config.pairs) { |tick| @bus.publish(:tick, tick) }
        @last_error = "ws currentPrices@futures: #{rt.message}" if rt.failure?

        ou = @ws.subscribe_order_updates do |payload|
          @journal.log_event('ws_order_update', ws_order_snippet(payload))
          @ws_fill_handler.handle(payload)
        rescue StandardError => e
          @logger.warn("order ws: #{e.message}")
        end
        @last_error = "ws order sub: #{ou.message}" if ou.failure?

        if @order_book_store
          @config.pairs.each do |pair|
            ob = @ws.subscribe_futures_order_book(instrument: pair, depth: 10) do |book|
              ltp_hint = order_book_ltp_hint(pair)
              @order_book_store.update(
                pair: book[:pair],
                bids: book[:bids],
                asks: book[:asks],
                ltp_hint: ltp_hint
              )
              @on_market_data&.call
            rescue StandardError => e
              @logger&.warn("order book ws #{pair}: #{e.message}")
            end
            @last_error = "ws orderbook #{pair}: #{ob.message}" if ob.failure?
          end
        end

        until @stop
          sleep 0.1
        end
      rescue StandardError => e
        @last_error = e.message
        @logger.error("[ws] session error: #{e.message}")
      end

      def tick_cycle
        @fx.refresh_if_stale!
        @journal.reset_daily_pnl_if_new_day!
        @daily_loss_flatten_warned = false unless @risk.daily_loss_breached?
        load_candles
        @hmm_runtime&.refresh!(@candles_exec)
        @ml_runtime&.refresh!(@candles_exec)
        emit_regime_hmm_transitions!
        seed_tracker_from_last_candle_if_no_ltp
        refresh_tracker_from_exec_candle_when_ws_stale
        mirror_tracker_into_tick_store
        run_paper_process_tick if @broker.paper?
        # Drain WS-tick-detected stop breaches before strategy (avoids double-close race).
        drain_stop_breach_queue
        maybe_flatten_on_daily_loss_breach
        # Entry gating must be **per pair**: if ETH has no WS ticks, SOL must still be allowed to open.
        # (TUI `snapshot.stale` remains `any?` so you still see a warning when any feed is dead.)
        @last_strategy_by_pair = {}
        run_smc_setup_evaluator!
        @config.pairs.each { |pair| process_pair(pair, ws_feed_stale?(pair)) }
        emit_price_rule_crossings!
        refresh_smc_setup_planner_if_due
        refresh_exchange_positions_for_tui_if_due
        refresh_regime_ai_if_due
        refresh_futures_wallet_for_tui_if_due
        refresh_runtime_reconcile_if_due
        apply_funding_for_live_positions!
        check_liquidation_risks
      rescue StandardError => e
        @last_error = e.message
        @logger.error(e.full_message)
      end

      # Cold start when REST returns before any WebSocket parseable tick.
      def seed_tracker_from_last_candle_if_no_ltp
        @config.pairs.each do |pair|
          next if @tracker.ltp(pair)

          exec = @candles_exec[pair] || []
          candle = exec.last
          next unless candle

          @tracker.record_tick(
            Dto::Tick.new(pair: pair, price: candle.close, received_at: Time.now)
          )
          touch_ws_staleness_clock_for_paper(pair)
        end
      end

      # While `ws_feed_stale?` is true, keep LTP/CHG in sync with the latest execution candle on each
      # `tick_cycle` (does not set `@ws_tick_at`; entries stay blocked until real WS ticks).
      def refresh_tracker_from_exec_candle_when_ws_stale
        @config.pairs.each do |pair|
          next unless ws_feed_stale?(pair)

          exec = @candles_exec[pair] || []
          candle = exec.last
          next unless candle

          chg = bar_change_pct_from_candle(candle)
          @tracker.record_tick(
            Dto::Tick.new(
              pair: pair,
              price: candle.close,
              change_pct: chg,
              received_at: Time.now
            )
          )
          touch_ws_staleness_clock_for_paper(pair)
        end
      end

      def bar_change_pct_from_candle(candle)
        o = candle.open
        c = candle.close
        return nil if o.nil? || c.nil?

        open_bd = BigDecimal(o.to_s)
        return nil if open_bd.zero?

        ((BigDecimal(c.to_s) - open_bd) / open_bd * 100).round(4)
      rescue ArgumentError, TypeError
        nil
      end

      # Paper only: advancing the WS clock when we mirror REST candles keeps STALE aligned with candle-driven
      # LTP when the TUI REST poller is off. Live never does this — entries still require real socket ticks unless dry_run.
      def touch_ws_staleness_clock_for_paper(pair)
        return unless paper_rest_advances_ws_stale_clock?

        @ws_tick_at[pair] = Time.now
      end

      def paper_rest_advances_ws_stale_clock?
        return false unless @config.dry_run?

        @config.runtime.fetch(:paper_rest_advances_ws_stale_clock, true)
      end

      def sleep_seconds_after_tick_cycle
        return @stale_recovery_sleep if @config.pairs.any? { |p| ws_feed_stale?(p) }

        @refresh
      end

      def load_candles
        @config.pairs.each do |pair|
          load_pair_resolution(pair, @htf_res, @candles_htf)
          load_pair_resolution(pair, @exec_res, @candles_exec)
        end
      end

      def load_pair_resolution(pair, resolution, store)
        from, to = candle_window(resolution, @lookback)
        res = @md.list_candlesticks(pair: pair, resolution: resolution, from: from, to: to)
        if res.failure?
          sleep 0.5
          res = @md.list_candlesticks(pair: pair, resolution: resolution, from: from, to: to)
        end
        unless res.ok?
          @logger.warn("[candles] #{pair}/#{resolution} fetch failed (using stale): #{res.message}")
          return
        end
        store[pair] = res.value
      end

      def candle_window(resolution, bars)
        mult = self.class.resolution_seconds(resolution)
        to = Time.now.to_i
        from = to - (bars * mult)
        [from, to]
      end

      def ws_order_snippet(payload)
        h =
          case payload
          when Hash
            payload.transform_keys(&:to_s)
          else
            { 'class' => payload.class.name }
          end
        keys = %w[event status id order_id client_order_id s p]
        h.slice(*keys).transform_values { |v| v.nil? ? '' : v.to_s }
      end

      def self.resolution_seconds(resolution)
        case resolution.to_s
        when /^(\d+)m$/
          ::Regexp.last_match(1).to_i * 60
        when /^(\d+)h$/
          ::Regexp.last_match(1).to_i * 3600
        when /^(\d+)d$/
          ::Regexp.last_match(1).to_i * 86_400
        else
          900
        end
      end

      # Periodic live position reconciliation: runs in a background thread to avoid blocking
      # tick_cycle. Cadence controlled by `runtime.runtime_reconcile_interval_seconds`.
      def refresh_runtime_reconcile_if_due
        return if @config.dry_run?
        return unless @config.runtime_reconcile_enabled?

        interval = @config.runtime_reconcile_interval_seconds
        now      = Time.now
        should_run = @runtime_reconcile_mutex.synchronize do
          at = @runtime_reconcile_at
          if at.nil? || (now - at) >= interval
            @runtime_reconcile_at = now
            true
          else
            false
          end
        end
        return unless should_run

        Thread.new do
          Thread.current.name = 'runtime_reconcile'
          @coord.reconcile_live_state!
        rescue StandardError => e
          @logger&.warn("[reconcile:runtime] #{e.message}")
        end
      end

      # For live open positions, estimate and deduct the CoinDCX 8-hour funding cost.
      # Marked as estimated because actual funding rates fluctuate; the default rate from
      # `risk.default_funding_rate_bps` (default 1 bps = 0.01 %) is a conservative estimate.
      def apply_funding_for_live_positions!
        return if @config.dry_run?
        return unless @config.track_funding_rate?

        rate_bps = @config.default_funding_rate_bps
        now      = Time.now.to_i

        @journal.open_positions.each do |pos|
          opened_at   = pos[:opened_at].to_i
          last_funded = pos[:last_funded_at]&.to_i || opened_at
          hours_since = (now - last_funded) / 3600.0
          next if hours_since < 8.0

          entry    = BigDecimal(pos[:entry_price].to_s)
          qty      = BigDecimal(pos[:quantity].to_s)
          notional = entry * qty
          funding_usdt = (notional * BigDecimal(rate_bps.to_s) / 10_000).round(8, BigDecimal::ROUND_UP)

          # Longs pay funding; shorts receive it.
          debit_usdt = pos[:side].to_s == 'long' ? funding_usdt : -funding_usdt
          debit_inr  = debit_usdt * @fx.inr_per_usdt

          @journal.apply_funding_to_position(id: pos[:id], funding_usdt: debit_usdt)
          @journal.add_daily_pnl_inr(-debit_inr)
          @journal.log_event(
            'funding_payment',
            pair:         pos[:pair],
            position_id:  pos[:id],
            funding_usdt: debit_usdt.to_s('F'),
            funding_inr:  debit_inr.to_s('F'),
            rate_bps:     rate_bps,
            estimated:    true
          )
          @logger&.info(
            "[funding] #{pos[:pair]} id=#{pos[:id]} debit=#{debit_usdt.to_s('F')} USDT (est. #{rate_bps} bps/8h)"
          )
        rescue StandardError => e
          @logger&.warn("[funding] pos #{pos[:id]}: #{e.message}")
        end
      end

      # Called from the WS-tick event (WS thread). Enqueues a stop breach without touching the
      # journal or coordinator (not thread-safe from the WS thread). The main tick_cycle thread
      # drains the queue and issues the close order atomically.
      def check_and_queue_stop_breach(tick)
        pos = @tracker.open_position_for(tick.pair)
        return unless pos

        stop_raw = pos[:stop_price]
        return unless stop_raw

        stop = BigDecimal(stop_raw.to_s)
        side = pos[:side].to_s
        ltp  = tick.price

        breached = (side == 'long' && ltp <= stop) || (side == 'short' && ltp >= stop)
        return unless breached

        @stop_breach_mutex.synchronize do
          @stop_breach_queue[tick.pair.to_s] ||= {
            position_id: pos[:id],
            stop_price:  stop,
            ltp:         ltp,
            side:        side,
            queued_at:   Time.now
          }
        end
      rescue StandardError => e
        @logger&.warn("[tick_stop] queue error #{tick.pair}: #{e.message}")
      end

      # Drain and process stop breaches queued by WS-tick callbacks.
      # Runs on the main engine thread — safe to call coordinator and journal.
      def drain_stop_breach_queue
        return if @config.dry_run? || !@config.exit_on_hard_stop?

        pending = @stop_breach_mutex.synchronize { @stop_breach_queue.dup.tap { @stop_breach_queue.clear } }
        return if pending.empty?

        pending.each do |pair, breach|
          next if @journal.paused? || @journal.kill_switch?

          pos = @journal.open_positions.find { |r| r[:id] == breach[:position_id] }
          next unless pos

          @logger&.warn(
            "[tick_stop] #{pair} stop breached: ltp=#{breach[:ltp]} stop=#{breach[:stop_price]} side=#{breach[:side]}"
          )
          sig = Strategy::Signal.new(
            action:     :close,
            pair:       pair,
            side:       breach[:side].to_sym,
            stop_price: nil,
            reason:     'tick_stop_breached',
            metadata:   { position_id: breach[:position_id] }
          )
          @coord.apply(sig, exit_price: breach[:ltp])
        rescue StandardError => e
          @logger&.error("[tick_stop] close failed #{pair}: #{e.message}")
        end
      end

      def process_pair(pair, stale)
        return if @journal.paused? || @journal.kill_switch?

        if smc_setup_skip_strategy_entries?(pair)
          hold = Strategy::Signal.new(
            action: :hold,
            pair: pair,
            side: nil,
            stop_price: nil,
            reason: 'smc_setup_pending',
            metadata: {}
          )
          @last_strategy_by_pair[pair.to_s] = { action: :hold, reason: 'smc_setup_pending' }
          log_strategy_signal(pair, hold) if @strategy_signal_trace
          return
        end

        htf = @candles_htf[pair] || []
        exec = @candles_exec[pair] || []
        pos = @tracker.open_position_for(pair)
        ltp = @tracker.ltp(pair)
        if pos && ltp
          u = CoindcxBot::Strategy::UnrealizedPnl.position_usdt(pos, ltp)
          unless u.nil?
            peak = @journal.bump_peak_unrealized_usdt(pos[:id], u)
            pos = pos.merge(peak_unrealized_usdt: peak.to_s('F')) if peak
          end
          pk = @journal.bump_peak_ltp(pos[:id], ltp)
          pos = pos.merge(peak_ltp: pk.to_s('F')) if pk
        end

        sig = @strategy.evaluate(
          pair: pair,
          candles_htf: htf,
          candles_exec: exec,
          position: pos,
          ltp: ltp,
          regime_hint: regime_hint_for(pair)
        )

        @last_strategy_by_pair[pair.to_s] = { action: sig.action, reason: sig.reason.to_s }

        maybe_log_analysis_strategy_transition(pair, sig, ltp)

        log_strategy_signal(pair, sig) if @strategy_signal_trace

        case sig.action
        when :hold
          return
        when :open_long, :open_short
          if stale
            @logger&.info("[engine] #{pair} #{sig.action} blocked: stale_feed (no WS tick within window)") if @strategy_signal_trace
            return
          end
          if @risk.daily_loss_breached?
            @logger&.info("[engine] #{pair} #{sig.action} blocked: daily_loss_limit") if @strategy_signal_trace
            return
          end

          gate = @risk.allow_new_entry?(open_positions: @journal.open_positions, pair: pair)
          unless gate.first == :ok
            @logger&.info("[engine] #{pair} #{sig.action} blocked: #{gate.last}") if @strategy_signal_trace
            return
          end

          entry = ltp || exec.last&.close
          unless entry
            @logger&.info("[engine] #{pair} #{sig.action} blocked: no_entry_price") if @strategy_signal_trace
            return
          end

          qty = @risk.size_quantity(entry_price: entry, stop_price: sig.stop_price, side: sig.side)
          if @regime_sizer
            mult = @regime_sizer.multiplier_for(@journal)
            qty = (qty * mult).round(6, BigDecimal::ROUND_DOWN)
          end
          if qty.nil? || qty <= 0
            @logger&.info("[engine] #{pair} #{sig.action} blocked: zero_quantity (check stop distance vs risk)") if @strategy_signal_trace
            return
          end

          unless @config.dry_run?
            lev = resolved_leverage
            margin_gate = @margin_sim.pre_trade_ok?(entry_price: entry, quantity: qty, leverage: lev)
            unless margin_gate.first == :ok
              @logger&.info("[engine] #{pair} #{sig.action} blocked: #{margin_gate.last}") if @strategy_signal_trace
              return
            end
          end

          @coord.apply(sig, quantity: qty, entry_price: entry)
        else
          exit_for_close = sig.action == :close ? ltp : nil
          @coord.apply(sig, exit_price: exit_for_close)
        end
      end

      # Effective leverage: coordinator config capped by ExposureGuard.max_leverage.
      def resolved_leverage
        defaults = @config.execution.fetch(:order_defaults, {})
        raw = defaults[:leverage] || defaults['leverage'] || @config.risk.fetch(:max_leverage, 5)
        requested = BigDecimal(raw.to_s).to_i
        [[requested, 1].max, @exposure.max_leverage].min
      rescue ArgumentError, TypeError
        1
      end

      # Scan open journal positions for liquidation proximity; log alerts and optionally
      # emergency-close positions where mark price is dangerously close to liquidation price.
      def check_liquidation_risks
        return if @config.dry_run?

        alert_pct     = @config.liquidation_alert_pct
        emergency_pct = @config.emergency_close_pct

        @journal.open_positions.each do |pos|
          ltp     = @tracker.ltp(pos[:pair])
          liq_raw = pos[:liquidation_price]
          next unless ltp && liq_raw

          liq = BigDecimal(liq_raw.to_s)
          mp  = BigDecimal(ltp.to_s)
          next unless liq.positive? && mp.positive?

          distance_pct = ((mp - liq).abs / mp * 100).round(2)

          if distance_pct < emergency_pct
            @logger&.error(
              "[liq_risk] EMERGENCY #{pos[:pair]} id=#{pos[:id]} " \
              "liq=#{liq.to_s('F')} mark=#{mp.to_s('F')} dist=#{distance_pct}% — force-closing"
            )
            sig = Strategy::Signal.new(
              action:     :close,
              pair:       pos[:pair],
              side:       pos[:side]&.to_sym,
              stop_price: nil,
              reason:     'liquidation_emergency',
              metadata:   { position_id: pos[:id] }
            )
            @coord.apply(sig, exit_price: ltp)
          elsif distance_pct < alert_pct
            @logger&.warn(
              "[liq_risk] #{pos[:pair]} id=#{pos[:id]} " \
              "liq=#{liq.to_s('F')} mark=#{mp.to_s('F')} dist=#{distance_pct}% — monitor closely"
            )
            @journal.log_event(
              'analysis_liquidation_proximity',
              pair: pos[:pair].to_s,
              position_id: pos[:id],
              distance_pct: distance_pct.to_s,
              mark: mp.to_s('F'),
              liquidation: liq.to_s('F'),
              dedupe_key: "pos_#{pos[:id]}"
            )
          end
        rescue StandardError => e
          @logger&.warn("[liq_risk] pos #{pos[:id]}: #{e.message}")
        end
      end

      # Read-only CoinDCX futures positions for TUI (POST list only; never places or exits orders).
      def exchange_positions_tui_for_snapshot
        return { rows: [], error: nil, fetched_at: nil } unless @config.tui_exchange_positions_enabled?

        @exchange_positions_tui_mutex.synchronize { @exchange_positions_tui.dup }
      end

      def refresh_exchange_positions_for_tui_if_due
        return unless @config.tui_exchange_positions_enabled?

        interval = @config.tui_exchange_positions_refresh_seconds
        now = Time.now
        @exchange_positions_tui_mutex.synchronize do
          at = @exchange_positions_tui[:fetched_at]
          return if at && (now - at) < interval
        end

        res = @account.list_positions(
          margin_currency_short_name: @config.tui_exchange_positions_margin_currencies,
          page: 1,
          size: 50
        )
        rows =
          if res.ok?
            normalize_exchange_positions_payload(res.value)
          else
            []
          end
        err = res.ok? ? nil : res.message.to_s
        @exchange_positions_tui_mutex.synchronize do
          @exchange_positions_tui = { rows: rows, error: err, fetched_at: Time.now }
        end
      rescue StandardError => e
        @logger&.warn("[tui] exchange positions: #{e.message}")
        @exchange_positions_tui_mutex.synchronize do
          @exchange_positions_tui = { rows: [], error: e.message, fetched_at: Time.now }
        end
      end

      def normalize_exchange_positions_payload(value)
        list =
          case value
          when Array
            value
          when Hash
            value[:positions] || value['positions'] || value[:data] || value['data'] || []
          else
            []
          end
        Array(list).map { |h| h.is_a?(Hash) ? h.transform_keys(&:to_sym) : {} }
      end

      def build_live_tui_metrics(exchange_rows, ticks_hash)
        return {} unless @config.tui_exchange_mirror?

        w = @futures_wallet_tui_mutex.synchronize { @futures_wallet_tui.dup }
        unreal = CoindcxBot::Tui::LiveAccountMirror.sum_unrealized_usdt(exchange_rows, ticks_hash)
        realized = CoindcxBot::Tui::LiveAccountMirror.sum_realized_usdt(exchange_rows)
        open_n = CoindcxBot::Tui::LiveAccountMirror.open_on_configured_pairs(exchange_rows, @config.pairs)
        h = {
          wallet_amount: w[:wallet_amount],
          wallet_currency: w[:wallet_currency],
          wallet_available: w[:wallet_available],
          wallet_locked: w[:wallet_locked],
          wallet_cross_order_margin: w[:wallet_cross_order_margin],
          wallet_cross_user_margin: w[:wallet_cross_user_margin],
          realized_usdt: realized,
          unrealized_usdt: unreal,
          open_positions_count: open_n,
          wallet_error: w[:error]
        }
        h.compact
      end

      def refresh_futures_wallet_for_tui_if_due
        return unless @config.tui_exchange_mirror?
        return if @config.dry_run?

        interval = @config.tui_exchange_positions_refresh_seconds
        now = Time.now
        @futures_wallet_tui_mutex.synchronize do
          at = @futures_wallet_tui[:fetched_at]
          return if at && (now - at) < interval
        end

        res = @account.futures_wallet(margin_currency_short_name: @config.margin_currency_short_name)
        snap = nil
        err = nil
        if res.ok?
          snap = CoindcxBot::Tui::LiveAccountMirror.extract_wallet_snapshot_for_display(
            res.value,
            @config.margin_currency_short_name,
            inr_per_usdt: inr_per_usdt
          )
          account_state = Models::AccountState.from_wallet_snapshot(snap)
          @margin_sim.update(account_state)
        else
          err = res.message.to_s
        end
        @futures_wallet_tui_mutex.synchronize do
          @futures_wallet_tui = {
            wallet_amount: snap&.dig(:balance),
            wallet_currency: snap&.dig(:currency),
            wallet_available: snap&.dig(:available_balance),
            wallet_locked: snap&.dig(:locked_balance),
            wallet_cross_order_margin: snap&.dig(:cross_order_margin),
            wallet_cross_user_margin: snap&.dig(:cross_user_margin),
            error: err,
            fetched_at: Time.now
          }
        end
      rescue StandardError => e
        @logger&.warn("[tui] futures wallet: #{e.message}")
        @futures_wallet_tui_mutex.synchronize do
          @futures_wallet_tui = {
            wallet_amount: nil,
            wallet_currency: nil,
            wallet_available: nil,
            wallet_locked: nil,
            wallet_cross_order_margin: nil,
            wallet_cross_user_margin: nil,
            error: e.message,
            fetched_at: Time.now
          }
        end
      end

      def maybe_log_analysis_strategy_transition(pair, sig, ltp)
        return unless @config.alerts_analysis_strategy_transitions?

        pair_s = pair.to_s
        fp = "#{sig.action}:#{sig.reason}"
        prev = @analysis_last_sig_fingerprint[pair_s]
        return if prev == fp

        # Initial transition check
        if prev.nil? && sig.action == :hold
          @analysis_last_sig_fingerprint[pair_s] = fp
          return
        end

        # Persistence check: require the same new fingerprint twice before alerting
        # to reduce chatter from flickering signals.
        candidate = @analysis_strategy_candidate[pair_s]
        if candidate == fp
          @analysis_strategy_candidate_count[pair_s] += 1
        else
          @analysis_strategy_candidate[pair_s] = fp
          @analysis_strategy_candidate_count[pair_s] = 1
        end

        return if @analysis_strategy_candidate_count[pair_s] < 2

        # Alert and confirm
        prev_action, prev_reason = prev.to_s.split(':', 2)
        @journal.log_event(
          'analysis_strategy_transition',
          pair: pair_s,
          from_action: prev_action,
          from_reason: prev_reason.to_s,
          to_action: sig.action.to_s,
          to_reason: sig.reason.to_s,
          ltp: ltp&.to_s,
          dedupe_key: "#{pair_s}|#{fp}"
        )
        @analysis_last_sig_fingerprint[pair_s] = fp
        @analysis_strategy_candidate[pair_s] = nil
        @analysis_strategy_candidate_count[pair_s] = 0
      end

      def emit_regime_hmm_transitions!
        return unless @hmm_runtime && @config.alerts_analysis_regime_hmm_transitions?

        min_post = @config.regime_hmm_alert_min_posterior
        min_stab = @config.regime_hmm_alert_min_stability_bars

        @config.pairs.each do |pair|
          st = @hmm_runtime.state_for(pair)
          next unless st

          cur = "#{st.state_id}:#{st.label}"
          prev = @analysis_last_hmm_state[pair]
          if prev.nil?
            @analysis_last_hmm_state[pair] = cur
            next
          end
          next if prev == cur

          if st.probability < min_post || st.consecutive_bars < min_stab || st.flickering || st.uncertainty
            @logger&.debug(
              "[regime_hmm] suppressed #{pair} #{prev}->#{cur} " \
              "post=#{(st.probability * 100).round(1)}% stab=#{st.consecutive_bars} " \
              "flick=#{st.flickering} unc=#{st.uncertainty}"
            )
            next
          end

          @analysis_last_hmm_state[pair] = cur
          prev_sid, prev_lbl = prev.split(':', 2)
          meaning = Regime::TransitionMeaning.describe(prev_lbl.to_s, st.label.to_s)
          @journal.log_event(
            'analysis_regime_change',
            pair: pair,
            from_state_id: prev_sid.to_s,
            from_label: prev_lbl.to_s,
            to_state_id: st.state_id.to_s,
            to_label: st.label.to_s,
            probability_pct: (st.probability * 100).round(2).to_s,
            stability_bars: st.consecutive_bars.to_s,
            vol_rank: st.vol_rank.to_s,
            vol_rank_total: st.vol_rank_total.to_s,
            flickering: st.flickering.to_s,
            confirmed: st.is_confirmed.to_s,
            meaning: meaning[:meaning].to_s,
            bias: meaning[:bias].to_s,
            action: meaning[:action].to_s,
            dedupe_key: "#{pair}|#{cur}"
          )
        end
      end

      def emit_price_rule_crossings!
        rules = @config.alerts_price_rules
        return if rules.empty?

        @config.pairs.each do |pair|
          ltp = @tracker.ltp(pair)
          next unless ltp

          events = CoindcxBot::Alerts::PriceRuleEvaluator.evaluate(
            rules: rules,
            pair: pair,
            ltp: ltp,
            last_side: @analysis_price_rule_zone
          )
          cd = @config.alerts_analysis_price_cross_cooldown_seconds
          now = Time.now
          events.each do |ev|
            next unless @price_cross_cooldown.permit_emit?(
              pair: ev[:pair],
              rule_id: ev[:rule_id],
              cooldown_seconds: cd,
              now: now
            )

            ctx = analysis_context_for_price_cross(ev[:pair])
            @journal.log_event(
              'analysis_price_cross',
              ev.merge(ctx).merge(dedupe_key: "#{ev[:pair]}|#{ev[:rule_id]}")
            )
          end
        end
      end

      def analysis_context_for_price_cross(pair)
        pair_s = pair.to_s
        out = {}
        ls = @last_strategy_by_pair[pair_s]
        if ls
          out[:strategy_action] = ls[:action].to_s
          out[:strategy_reason] = ls[:reason].to_s
        end
        if @hmm_runtime
          st = @hmm_runtime.state_for(pair_s)
          if st
            out[:hmm_state_id] = st.state_id.to_s
            out[:hmm_label] = st.label.to_s
            out[:hmm_posterior_pct] = (st.probability * 100.0).round(2).to_s
            out[:hmm_vol_rank] = "#{st.vol_rank}/#{st.vol_rank_total}"
            out[:hmm_uncertain] = st.uncertainty ? 'true' : 'false'
          end
        end
        snap = @regime_ai_mutex.synchronize { @regime_ai_state[:payload] }
        if snap.is_a?(Hash)
          ph = snap.transform_keys(&:to_sym)
          lab = ph[:regime_label].to_s.strip
          out[:regime_ai_label] = lab unless lab.empty?
          pct = ph[:probability_pct]
          unless pct.nil?
            out[:regime_ai_probability_pct] =
              if pct.is_a?(Numeric)
                pct.round(2).to_s('F')
              else
                pct.to_s.strip
              end
          end
        end
        out
      end

      def maybe_log_regime_ai_transition!(prev_payload, new_payload)
        return unless @config.alerts_analysis_regime_ai_updates?
        return unless new_payload.is_a?(Hash)

        new_h = new_payload.transform_keys(&:to_sym)
        prev_h = prev_payload.is_a?(Hash) ? prev_payload.transform_keys(&:to_sym) : {}
        return if prev_h.empty?

        new_l = new_h[:regime_label].to_s
        old_l = prev_h[:regime_label].to_s

        new_p = regime_ai_probability_float(new_h[:probability_pct])
        old_p = regime_ai_probability_float(prev_h[:probability_pct])
        delta = (new_p - old_p).abs

        # Noise reduction:
        # 1. Label change is always interesting to a trader.
        # 2. Probability crossing 70% or 90% is interesting (conviction level).
        # 3. Massive jumps (e.g. 25%) are interesting.
        label_changed = new_l != old_l && !(new_l.empty? && old_l.empty?)
        crossed_threshold = (old_p < 70 && new_p >= 70) || (old_p < 90 && new_p >= 90)
        massive_jump = delta >= 25.0

        significant = label_changed || crossed_threshold || massive_jump

        return unless significant

        trans = (new_h[:transition_summary]).to_s
        @journal.log_event(
          'analysis_regime_ai_update',
          regime_label: new_l,
          prev_label: old_l,
          probability_pct: new_p.to_s,
          prev_probability_pct: old_p.to_s,
          transition_summary: trans,
          dedupe_key: 'regime_ai_global'
        )
      end

      def regime_ai_probability_float(raw)
        Float(raw || 0)
      rescue ArgumentError, TypeError
        0.0
      end
    end
  end
end
