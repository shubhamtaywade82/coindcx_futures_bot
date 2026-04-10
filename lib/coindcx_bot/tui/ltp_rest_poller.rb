# frozen_string_literal: true

module CoindcxBot
  module Tui
    # Fast REST polls into `TickStore` for TUI LTP/CHG%/AGE (and L1 bid/ask when available). Does not publish engine
    # `:tick` or move `@ws_tick_at`.
    # Uses the public futures `current_prices` RT snapshot (`ls` / `pc` — typically **no** bid/ask); when both are
    # missing after a batch hit, enriches from `fetch_instrument_display_quote` so MARKET DEPTH columns can populate.
    # Falls back to per-pair display quote when the snapshot misses a symbol entirely.
    class LtpRestPoller
      def initialize(market_data:, pairs:, tick_store:, render_loop:, interval_seconds:, logger: nil)
        @market_data = market_data
        @pairs = Array(pairs).map(&:to_s)
        @tick_store = tick_store
        @render_loop = render_loop
        @interval_seconds = interval_seconds.to_f
        @logger = logger
        @stop = false
        @mutex = Mutex.new
      end

      def start
        @thread = Thread.new do
          Thread.current.report_on_exception = false
          run_loop
        end
      end

      def stop
        @mutex.synchronize { @stop = true }
        @thread&.join(5)
      end

      private

      def run_loop
        until stopped?
          cycle_started = Time.now
          refresh_all_pairs
          @render_loop&.request_redraw unless stopped?
          sleep_remaining(cycle_started) unless stopped?
        end
      rescue StandardError => e
        @logger&.warn("TUI LTP poll: #{e.message}")
      end

      def refresh_all_pairs
        res = @market_data.fetch_futures_rt_quotes(pairs: @pairs)
        if res.ok? && res.value.is_a?(Hash) && res.value.any?
          @pairs.each do |pair|
            break if stopped?

            q = res.value[pair]
            if q && q[:price]
              write_tick_store(pair, q[:price], q[:change_pct], bid: q[:bid], ask: q[:ask])
              enrich_depth_from_instrument(pair) if q[:bid].nil? && q[:ask].nil?
            else
              refresh_pair(pair)
            end
          end
        else
          @pairs.each do |pair|
            break if stopped?

            refresh_pair(pair)
          end
        end
      end

      def refresh_pair(pair)
        res = @market_data.fetch_instrument_display_quote(pair: pair)
        return unless res.ok?

        q = res.value
        return unless q[:price]

        write_tick_store(pair, q[:price], q[:change_pct], bid: q[:bid], ask: q[:ask])
      end

      def write_tick_store(pair, price, change_pct, bid: nil, ask: nil)
        @tick_store.update(
          symbol: pair,
          ltp: price,
          change_pct: change_pct,
          updated_at: Time.now,
          bid: bid,
          ask: ask
        )
      end

      # RT batch quotes are usually last + % only; instrument REST often includes best bid/ask for L1 display.
      def enrich_depth_from_instrument(pair)
        res = @market_data.fetch_instrument_display_quote(pair: pair)
        return unless res.ok?

        q = res.value
        return if q[:bid].nil? && q[:ask].nil?

        tick = @tick_store.snapshot[pair]
        price = tick&.ltp || q[:price]
        @tick_store.update(
          symbol: pair,
          ltp: price,
          change_pct: nil,
          updated_at: Time.now,
          bid: q[:bid],
          ask: q[:ask]
        )
      end

      def sleep_remaining(cycle_started)
        elapsed = Time.now - cycle_started
        remain = @interval_seconds - elapsed
        sleep(remain) if remain.positive?
      end

      def stopped?
        @mutex.synchronize { @stop }
      end
    end
  end
end
