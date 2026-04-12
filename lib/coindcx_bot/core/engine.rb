# frozen_string_literal: true

require 'bigdecimal'
require 'json'
require 'logger'

require_relative '../display_ltp'
require_relative '../regime/tui_state'
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
        keyword_init: true
      )

      def initialize(config:, logger: nil, tick_store: nil, on_tick: nil, order_book_store: nil,
                     on_market_data: nil)
        @config = config
        @logger = logger || Logger.new($stdout)
        @journal = Persistence::Journal.new(config.journal_path)
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
        @fx = Fx::UsdtInrRate.new(client: @client, config: config, logger: @logger)
        @risk = Risk::Manager.new(config: config, journal: @journal, exposure_guard: @exposure, fx: @fx)
        @strategy = build_strategy(config.strategy)

        @md = Gateways::MarketDataGateway.new(
          client: @client,
          margin_currency_short_name: config.margin_currency_short_name
        )
        @orders = Gateways::OrderGateway.new(
          client: @client,
          order_defaults: config.execution.fetch(:order_defaults, {})
        )
        @account = Gateways::AccountGateway.new(client: @client)
        @ws = Gateways::WsGateway.new(client: @client, logger: @logger)
        @broker = build_broker(config)
        @coord = Execution::Coordinator.new(
          broker: @broker,
          journal: @journal,
          config: config,
          exposure_guard: @exposure,
          logger: @logger,
          fx: @fx
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
        @regime_ai_mutex = Mutex.new
        @regime_ai_state = { updated_at: nil, payload: nil, error: nil }
        @regime_ai_brain = nil
        @hmm_runtime = Regime::HmmRuntime.new(config: @config, logger: @logger) if @config.regime_hmm_enabled?
        @regime_sizer = Risk::RegimeSizer.new(@config) if @config.regime_risk_enabled?
        @daily_loss_flatten_warned = false
        @engine_loop_crashed = false
        @exchange_positions_tui_mutex = Mutex.new
        @exchange_positions_tui = { rows: [], error: nil, fetched_at: nil }
        @smc_setup_store = nil
        @smc_setup_eval = nil
        @smc_setup_planner = nil
        @smc_setup_planner_state = { updated_at: nil, error: nil }
        @smc_setup_mutexes = Hash.new { |h, k| h[k] = Mutex.new }
        init_smc_setup_stack! if @config.smc_setup_enabled?

        @bus.subscribe(:tick) do |tick|
          @ws_tick_at[tick.pair] = Time.now
          @tracker.record_tick(tick)
          forward_tick_to_store(tick)
          @logger&.info("[ws] tick #{tick.pair} #{tick.price}") if ENV['COINDCX_WS_TRACE'].to_s == '1'
          @on_tick&.call(tick)
        end

        @ws_shutdown_timeout = config.runtime.fetch(:ws_shutdown_join_seconds, 45).to_f
        @strategy_signal_trace = strategy_signal_trace_enabled?(config)
      end

      attr_reader :config, :logger, :journal, :broker

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
          [p, { price: @tracker.ltp(p), at: tick_at }]
        end
        stale = @config.pairs.any? { |p| ws_feed_stale?(p) }

        pm = @broker.paper? ? paper_snapshot_metrics(ticks) : {}

        ex = exchange_positions_tui_for_snapshot
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
          exchange_positions_fetched_at: ex[:fetched_at]
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
        ws_thread = Thread.new { run_ws_loop }
        loop do
          break if @stop

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
          merged = merged.merge(@hmm_runtime.tui_overlay)
        end
        return merged unless @config.regime_ai_enabled?

        snap = @regime_ai_mutex.synchronize { @regime_ai_state.dup }
        merged.merge(Regime::AiBrain.overlay_from_state(snap))
      end

      def refresh_regime_ai_if_due
        return unless @config.regime_ai_enabled?

        now = Time.now
        @regime_ai_mutex.synchronize do
          last = @regime_ai_state[:updated_at]
          return if last && (now - last) < @config.regime_ai_min_interval_seconds
        end

        ctx = build_regime_ai_context
        if @config.regime_ai_include_hmm_context? && @hmm_runtime
          ctx[:hmm] = @hmm_runtime.hmm_context_for_ai
        end
        return if ctx[:pairs].empty?

        brain = (@regime_ai_brain ||= Regime::AiBrain.new(config: @config, logger: @logger))
        res = brain.analyze!(ctx)
        @regime_ai_mutex.synchronize do
          @regime_ai_state[:updated_at] = now
          if res.ok && res.payload
            @regime_ai_state[:payload] = res.payload
            @regime_ai_state[:error] = nil
          else
            @regime_ai_state[:error] = res.error_message
          end
        end
      rescue StandardError => e
        @logger&.warn("[regime_ai] #{e.class}: #{e.message}")
        @regime_ai_mutex.synchronize { @regime_ai_state[:error] = e.message }
      end

      def maybe_flatten_on_daily_loss_breach
        return unless @config.flatten_on_daily_loss_breach?
        return unless @risk.daily_loss_breached?
        return if @journal.open_positions.empty?
        return if @journal.paused? || @journal.kill_switch?

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
        pairs = @config.pairs.first(max_pairs)
        candles_by_pair = pairs.to_h do |p|
          arr = Array(@candles_exec[p]).last(n)
          rows = arr.map do |c|
            { o: c.open, h: c.high, l: c.low, c: c.close, v: c.volume }
          end
          [p, rows]
        end
        {
          pairs: pairs,
          candles_by_pair: candles_by_pair,
          positions: @journal.open_positions,
          exec_resolution: @exec_res,
          htf_resolution: @htf_res
        }
      end

      def regime_hint_for(pair)
        return nil unless @hmm_runtime

        st = @hmm_runtime.state_for(pair)
        return nil unless st

        {
          tier: Regime::Allocation.vol_tier(st.vol_rank, st.vol_rank_total),
          state: st
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

      def refresh_smc_setup_planner_if_due
        return unless @config.smc_setup_planner_enabled?
        return unless @smc_setup_store

        now = Time.now
        last = @smc_setup_planner_state[:updated_at]
        return if last && (now - last) < @config.smc_setup_planner_interval_seconds

        ctx = build_smc_planner_context
        return if ctx[:pairs].empty?

        brain = (@smc_setup_planner ||= SmcSetup::PlannerBrain.new(config: @config, logger: @logger))
        res = brain.plan!(ctx)
        @smc_setup_planner_state[:updated_at] = now
        if res.ok && res.payload
          begin
            @smc_setup_store.upsert_from_hash!(
              res.payload,
              reset_state: @config.smc_setup_planner_reset_state?
            )
            sid = res.payload[:setup_id] || res.payload['setup_id']
            pair = res.payload[:pair] || res.payload['pair']
            @logger&.info("[smc_setup:planner] upserted setup_id=#{sid} pair=#{pair} (Ollama → TradeSetup store)")
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

      def build_smc_planner_context
        pairs = @config.pairs
        n = 24
        candles_by_pair = pairs.to_h do |p|
          arr = Array(@candles_exec[p]).last(n)
          rows = arr.map do |c|
            { o: c.open, h: c.high, l: c.low, c: c.close, v: c.volume }
          end
          [p, rows]
        end
        {
          pairs: pairs,
          candles_by_pair: candles_by_pair,
          open_count: @journal.open_positions.size,
          exec_resolution: @exec_res,
          htf_resolution: @htf_res
        }
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
          c.api_key = ENV.fetch('COINDCX_API_KEY').to_s.strip
          c.api_secret = ENV.fetch('COINDCX_API_SECRET').to_s.strip
          c.logger = @logger

          if @config.paper_exchange_enabled?
            base = @config.paper_exchange_api_base
            c.api_base_url = base unless base.empty?
          end

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

      def run_ws_loop
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
        @logger.error("WS loop: #{e.full_message}")
      end

      def tick_cycle
        @fx.refresh_if_stale!
        @journal.reset_daily_pnl_if_new_day!
        @daily_loss_flatten_warned = false unless @risk.daily_loss_breached?
        load_candles
        @hmm_runtime&.refresh!(@candles_exec)
        seed_tracker_from_last_candle_if_no_ltp
        refresh_tracker_from_exec_candle_when_ws_stale
        mirror_tracker_into_tick_store
        run_paper_process_tick if @broker.paper?
        maybe_flatten_on_daily_loss_breach
        # Entry gating must be **per pair**: if ETH has no WS ticks, SOL must still be allowed to open.
        # (TUI `snapshot.stale` remains `any?` so you still see a warning when any feed is dead.)
        @last_strategy_by_pair = {}
        run_smc_setup_evaluator!
        @config.pairs.each { |pair| process_pair(pair, ws_feed_stale?(pair)) }
        refresh_smc_setup_planner_if_due
        refresh_regime_ai_if_due
        refresh_exchange_positions_for_tui_if_due
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
        unless res.ok?
          @logger.warn("candles #{pair} #{resolution}: #{res.message}")
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

          @coord.apply(sig, quantity: qty, entry_price: entry)
        else
          exit_for_close = sig.action == :close ? ltp : nil
          @coord.apply(sig, exit_price: exit_for_close)
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
    end
  end
end
