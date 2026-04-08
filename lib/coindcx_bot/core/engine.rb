# frozen_string_literal: true

require 'logger'

module CoindcxBot
  module Core
    class Engine
      Snapshot = Struct.new(
        :pairs, :ticks, :positions, :paused, :kill_switch, :stale, :last_error, :daily_pnl,
        :running, :dry_run, :stale_tick_seconds, keyword_init: true
      )

      def initialize(config:, logger: nil)
        @config = config
        @logger = logger || Logger.new($stdout)
        @journal = Persistence::Journal.new(config.journal_path)
        @bus = EventBus.new
        @stale_seconds = config.runtime.fetch(:stale_tick_seconds, 45).to_i
        @stale_recovery_sleep = config.runtime.fetch(:stale_recovery_sleep_seconds, 5).to_f
        @tracker = PositionTracker.new(
          journal: @journal,
          stale_tick_seconds: @stale_seconds
        )
        @exposure = Risk::ExposureGuard.new(config: config)
        @risk = Risk::Manager.new(config: config, journal: @journal, exposure_guard: @exposure)
        @strategy = Strategy::TrendContinuation.new(config.strategy)

        configure_coin_dcx
        @client = CoinDCX.client
        @md = Gateways::MarketDataGateway.new(
          client: @client,
          margin_currency_short_name: config.margin_currency_short_name
        )
        @orders = Gateways::OrderGateway.new(
          client: @client,
          order_defaults: config.execution.fetch(:order_defaults, {})
        )
        @account = Gateways::AccountGateway.new(client: @client)
        @ws = Gateways::WsGateway.new(client: @client)
        @coord = Execution::Coordinator.new(
          order_gateway: @orders,
          account_gateway: @account,
          journal: @journal,
          config: config,
          exposure_guard: @exposure,
          logger: @logger
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

        @bus.subscribe(:tick) do |tick|
          @ws_tick_at[tick.pair] = Time.now
          @tracker.record_tick(tick)
        end

        @ws_shutdown_timeout = config.runtime.fetch(:ws_shutdown_join_seconds, 45).to_f
      end

      attr_reader :config, :logger, :journal

      def snapshot
        ticks = @config.pairs.to_h do |p|
          tick_at = @tracker.last_tick_at(p)
          [p, { price: @tracker.ltp(p), at: tick_at }]
        end
        stale = @config.pairs.any? { |p| ws_feed_stale?(p) }
        Snapshot.new(
          pairs: @config.pairs,
          ticks: ticks,
          positions: @journal.open_positions,
          paused: @journal.paused?,
          kill_switch: @journal.kill_switch?,
          stale: stale,
          last_error: @last_error,
          daily_pnl: @journal.daily_pnl_inr,
          running: !@stop,
          dry_run: @config.dry_run?,
          stale_tick_seconds: @stale_seconds
        )
      end

      def request_stop!
        @stop = true
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
        @coord.flatten_all(@config.pairs)
      end

      def run
        ws_thread = Thread.new { run_ws_loop }
        loop do
          break if @stop

          tick_cycle
          break if @stop

          sleep sleep_seconds_after_tick_cycle
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

      def configure_coin_dcx
        CoinDCX.configure do |c|
          c.api_key = ENV.fetch('COINDCX_API_KEY')
          c.api_secret = ENV.fetch('COINDCX_API_SECRET')
          c.logger = @logger

          url = ENV['COINDCX_SOCKET_BASE_URL'].to_s.strip
          c.socket_base_url = url unless url.empty?

          if c.respond_to?(:socket_io_connect_options=)
            eio = ENV['COINDCX_SOCKET_EIO'].to_s.strip
            c.socket_io_connect_options = eio.empty? ? { EIO: 4 } : { EIO: Integer(eio) }
          end
        end
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

        ou = @ws.subscribe_order_updates do |payload|
          @journal.log_event('ws_order_update', ws_order_snippet(payload))
        rescue StandardError => e
          @logger.warn("order ws: #{e.message}")
        end
        @last_error = "ws order sub: #{ou.message}" if ou.failure?

        until @stop
          sleep 0.1
        end
      rescue StandardError => e
        @last_error = e.message
        @logger.error("WS loop: #{e.full_message}")
      end

      def tick_cycle
        @journal.reset_daily_pnl_if_new_day!
        load_candles
        seed_tracker_from_last_candle_if_no_ltp
        stale = @config.pairs.any? { |p| ws_feed_stale?(p) }
        @last_error = 'stale_feed' if stale

        @config.pairs.each { |pair| process_pair(pair, stale) }
      rescue StandardError => e
        @last_error = e.message
        @logger.error(e.full_message)
      end

      # Only when we have never seen a price (WS slower than first REST load). Do not touch LTP when
      # WS goes quiet — that would fake a fresh tick and hide `ws_feed_stale?` / unblock entries wrongly.
      def seed_tracker_from_last_candle_if_no_ltp
        @config.pairs.each do |pair|
          next if @tracker.ltp(pair)

          exec = @candles_exec[pair] || []
          candle = exec.last
          next unless candle

          @tracker.record_tick(
            Dto::Tick.new(pair: pair, price: candle.close, received_at: Time.now)
          )
        end
      end

      def ws_feed_stale?(pair)
        at = @ws_tick_at[pair]
        return true unless at

        Time.now - at > @stale_seconds
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

        htf = @candles_htf[pair] || []
        exec = @candles_exec[pair] || []
        pos = @tracker.open_position_for(pair)
        ltp = @tracker.ltp(pair)

        sig = @strategy.evaluate(
          pair: pair,
          candles_htf: htf,
          candles_exec: exec,
          position: pos,
          ltp: ltp
        )

        case sig.action
        when :hold
          return
        when :open_long, :open_short
          return if stale
          return if @risk.daily_loss_breached?

          gate = @risk.allow_new_entry?(open_positions: @journal.open_positions, pair: pair)
          return unless gate.first == :ok

          entry = ltp || exec.last&.close
          return unless entry

          qty = @risk.size_quantity(entry_price: entry, stop_price: sig.stop_price, side: sig.side)
          @coord.apply(sig, quantity: qty, entry_price: entry)
        else
          @coord.apply(sig)
        end
      end
    end
  end
end
