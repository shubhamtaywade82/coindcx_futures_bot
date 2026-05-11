# frozen_string_literal: true

require 'bigdecimal'

module CoindcxBot
  module MarketData
    # Feeds +Risk::DivergenceGuard+ from Binance bookTicker and CoinDCX +Gateways::WsGateway+ ticks; publishes transition-only bus events.
    class DivergenceMonitor
      EVENT_OK = 'risk.divergence.ok'
      EVENT_EXCEEDED = 'risk.divergence.exceeded'
      EVENT_RECOVERED = 'risk.divergence.recovered'

      def initialize(
        bus:,
        guard:,
        pair:,
        binance_symbol:,
        ws_gateway: nil,
        stub_coindcx: false,
        logger: nil,
        check_interval_ms: 250
      )
        @bus = bus
        @guard = guard
        @pair = pair.to_s
        @binance_symbol = binance_symbol.to_s.upcase
        @ws_gateway = ws_gateway
        @stub_coindcx = stub_coindcx
        @logger = logger
        @check_interval_ms = [Integer(check_interval_ms), 50].max
        @tick_mutex = Mutex.new
        @gate_state = :unset
        @last_result = nil
        @check_thread = nil
        @stop = false
        @started = false
      end

      def start
        raise 'DivergenceMonitor already started' if @started

        @started = true
        @stop = false
        connect_and_wire_coindcx unless @stub_coindcx
        start_check_loop
        self
      end

      def stop
        @stop = true
        @check_thread&.join(2)
        @check_thread = nil
        @started = false
        self
      end

      # Invoked by +Orderflow::BinanceAdapter+ when +book_ticker_ws+ is wired.
      def on_binance_book_ticker(best_bid:, best_ask:, ts:)
        mid = mid_from_sides(best_bid, best_ask)
        return if mid.nil?

        wall_ts = Integer(ts)
        wall_ts = (Time.now.to_f * 1000).to_i unless wall_ts.positive?
        @guard.update_binance_mid(symbol: @binance_symbol, mid: mid, ts: wall_ts)
        mirror_stub_if_needed(mid, wall_ts)
        tick_check
      end

      # Test hook: push CoinDCX side without a live +WsGateway+.
      def feed_coindcx_mid(mid:, ts:)
        @guard.update_coindcx_mid(pair: @pair, mid: mid, ts: ts)
        tick_check
      end

      def snapshot
        @tick_mutex.synchronize do
          res = @last_result
          gate = @gate_state
          return { pair: @pair, status: gate, bps: nil, age_ms: nil, reason: nil } if res.nil?

          if res.ok?
            { pair: @pair, status: gate, bps: res.value[:bps], age_ms: res.value[:age_ms], reason: nil }
          else
            v = res.value || {}
            { pair: @pair, status: gate, bps: v[:bps], age_ms: v[:age_ms], reason: v[:reason] || res.code }
          end
        end
      end

      private

      def connect_and_wire_coindcx
        return if @ws_gateway.nil?

        @ws_gateway.connect
        res = @ws_gateway.subscribe_futures_prices(instrument: @pair) do |tick|
          on_coindcx_tick(tick)
        end
        @logger&.warn("[divergence_monitor] subscribe_futures_prices failed: #{res.message}") if res.failure?
      rescue StandardError => e
        @logger&.warn("[divergence_monitor] CoinDCX WS: #{e.message}")
      end

      def on_coindcx_tick(tick)
        mid = coindcx_mid_from_tick(tick)
        return if mid.nil?

        ts = coindcx_ts_ms(tick)
        @guard.update_coindcx_mid(pair: @pair, mid: mid, ts: ts)
        tick_check
      rescue StandardError => e
        @logger&.warn("[divergence_monitor] coindcx tick: #{e.message}")
      end

      def coindcx_mid_from_tick(tick)
        bid = tick.respond_to?(:bid) ? tick.bid : nil
        ask = tick.respond_to?(:ask) ? tick.ask : nil
        mid_from_sides(bid, ask) || tick&.price
      end

      def coindcx_ts_ms(tick)
        if tick.respond_to?(:received_at) && tick.received_at
          (tick.received_at.to_f * 1000).to_i
        else
          (Time.now.to_f * 1000).to_i
        end
      end

      def mid_from_sides(bid, ask)
        return nil if bid.nil? || ask.nil?

        b = bid.is_a?(BigDecimal) ? bid : BigDecimal(bid.to_s)
        a = ask.is_a?(BigDecimal) ? ask : BigDecimal(ask.to_s)
        return nil unless b.positive? && a.positive? && a > b

        (b + a) / 2
      rescue ArgumentError, TypeError
        nil
      end

      def mirror_stub_if_needed(mid, ts)
        return unless @stub_coindcx

        @guard.update_coindcx_mid(pair: @pair, mid: mid, ts: ts)
      end

      def start_check_loop
        @check_thread = Thread.new do
          until @stop
            tick_check
            sleep(@check_interval_ms / 1000.0)
          end
        end
      end

      def tick_check
        publish = nil
        @tick_mutex.synchronize do
          result = @guard.check(pair: @pair)
          @last_result = result

          if result.ok?
            transition =
              case @gate_state
              when :err
                @gate_state = :ok
                :recovered
              when :unset
                @gate_state = :ok
                :first_ok
              else
                @gate_state = :ok
                nil
              end
            publish = [:recovered, result] if transition == :recovered
            publish = [:ok, result] if transition == :first_ok
          else
            reason = (result.value || {})[:reason] || result.code
            unless reason == :missing_data
              transition =
                if @gate_state == :ok || @gate_state == :unset
                  @gate_state = :err
                  :exceeded
                end
              publish = [:exceeded, result] if transition == :exceeded
            end
          end
        end

        if publish
          kind, res = publish
          case kind
          when :recovered
            @bus.publish(EVENT_RECOVERED, recovery_payload(res))
          when :ok
            @bus.publish(EVENT_OK, ok_payload(res))
          when :exceeded
            @bus.publish(EVENT_EXCEEDED, exceeded_payload(res))
          end
        end
      rescue StandardError => e
        @logger&.warn("[divergence_monitor] check: #{e.message}")
      end

      def ok_payload(result)
        {
          pair: @pair,
          bps: result.value[:bps],
          age_ms: result.value[:age_ms]
        }
      end

      def recovery_payload(result)
        ok_payload(result)
      end

      def exceeded_payload(result)
        v = result.value || {}
        {
          pair: @pair,
          reason: v[:reason] || result.code,
          bps: v[:bps],
          age_ms: v[:age_ms]
        }
      end
    end
  end
end
