# frozen_string_literal: true

require 'bigdecimal'

module CoindcxBot
  module Orderflow
    # Detects rapid consumption of displayed top-of-book liquidity (Binance deltas or CoinDCX diffs).
    class SweepDetector
      DEFAULT_MIN_LEVELS = 3
      DEFAULT_WINDOW_MS = 200
      DEFAULT_DISPLACEMENT_ATR_MULT = BigDecimal('0.3')
      DEFAULT_TICK = BigDecimal('0.01')

      def initialize(bus:, config:)
        @bus = bus
        @config = config
        @mutex = Mutex.new
        @streak = { bid: [], ask: [] }
        @mid_ring = []
        @mid_ring_max = 80
      end

      # Optional mid samples (Binance +LocalBook#mid+ or CoinDCX snapshot mids) for ATR-style span.
      def record_mid(pair:, mid:, ts_ms:)
        return if mid.nil?

        m = mid.is_a?(BigDecimal) ? mid : BigDecimal(mid.to_s)
        @mutex.synchronize do
          @mid_ring << { pair: pair.to_s, ts_ms: Integer(ts_ms), mid: m }
          @mid_ring.shift while @mid_ring.size > @mid_ring_max
          prune_ring_unlocked!(ts_ms)
        end
      end

      # Binance +LocalBook+ delta row (+was_best+ from LocalBook).
      def feed_local_delta(pair:, source:, delta:)
        return unless delta[:action] == :remove && delta[:was_best]

        side = delta[:side] == :bid ? :bid : :ask
        push_removal(pair: pair, source: source, side: side, price: delta[:price], qty: delta[:prev_qty], ts_ms: delta[:ts_ms])
      end

      # CoinDCX-style transition using engine +OrderBookStore+ diff + snapshots.
      def feed_coindcx_book(pair:, source:, prev_snap:, diff:, snap:)
        return unless prev_snap && diff && snap

        ts_ms = (diff.timestamp.to_f * 1000).to_i
        m = compute_snap_mid(snap)
        record_mid(pair: pair, mid: m, ts_ms: ts_ms) if m

        record_best_removals(pair, source, :bid, diff.bid_removed, prev_snap[:bids], ts_ms)
        record_best_removals(pair, source, :ask, diff.ask_removed, prev_snap[:asks], ts_ms)
      end

      def reset!(_pair = nil)
        @mutex.synchronize do
          @streak[:bid].clear
          @streak[:ask].clear
          @mid_ring.clear
        end
      end

      private

      def record_best_removals(pair, source, side, removed_map, prev_side_snap, ts_ms)
        return if removed_map.empty?

        best = best_price_string(prev_side_snap, side)
        return unless best

        best_bd = BigDecimal(best.to_s)
        removed_map.each do |price_str, size|
          p = BigDecimal(price_str.to_s)
          next unless p == best_bd

          push_removal(pair: pair, source: source, side: side, price: p, qty: BigDecimal(size.to_s), ts_ms: ts_ms)
        end
      end

      def best_price_string(side_hash, side)
        keys = side_hash.keys
        return nil if keys.empty?

        floats = keys.map { |k| Float(k) }
        side == :bid ? floats.max&.to_s : floats.min&.to_s
      rescue ArgumentError, TypeError
        nil
      end

      def push_removal(pair:, source:, side:, price:, qty:, ts_ms:)
        streak_snapshot = nil
        ring_snapshot = nil
        ts_i = Integer(ts_ms)

        @mutex.synchronize do
          st = @streak[side]
          prune_streak!(st, ts_i)
          st << { ts_ms: ts_i, price: price, qty: qty }
          prune_streak!(st, ts_i)
          streak_snapshot = st.dup
          ring_snapshot = @mid_ring.dup
        end

        try_emit(pair: pair, source: source, side: side, streak: streak_snapshot, ring: ring_snapshot, ts_ms: ts_i)
      end

      def compute_snap_mid(snap)
        bids = snap[:bids]
        asks = snap[:asks]
        return nil if bids.empty? || asks.empty?

        bb = bids.keys.map { |k| BigDecimal(k.to_s) }.max
        ba = asks.keys.map { |k| BigDecimal(k.to_s) }.min
        return nil unless bb && ba && bb < ba

        (bb + ba) / 2
      rescue ArgumentError, TypeError
        nil
      end

      def prune_streak!(streak, now_ms)
        win = window_ms
        streak.reject! { |row| now_ms - row[:ts_ms] > win }
      end

      def prune_ring_unlocked!(now_ms)
        win = window_ms
        @mid_ring.reject! { |row| now_ms - row[:ts_ms] > win * 20 }
      end

      def try_emit(pair:, source:, side:, streak:, ring:, ts_ms:)
        return if streak.size < min_levels

        span_ms = streak.last[:ts_ms] - streak.first[:ts_ms]
        return unless span_ms <= window_ms

        atr = atr_proxy_for_pair(pair, ring, ts_ms)
        return if atr <= 0

        displacement = (streak.last[:price] - streak.first[:price]).abs
        return unless displacement > atr * displacement_atr_mult

        notional = streak.sum { |r| (r[:qty] * r[:price]).to_f }

        @bus.publish(
          :'liquidity.sweep.detected',
          {
            source: source,
            symbol: pair,
            side: side == :bid ? :bid : :ask,
            levels_swept: streak.size,
            notional: BigDecimal(notional.to_s).round(8),
            ts: ts_ms,
            pair: pair
          }
        )
        @mutex.synchronize { @streak[side].clear }
      end

      def atr_proxy_for_pair(pair, ring, now_ms)
        win = window_ms
        relevant = ring.select do |row|
          row[:pair] == pair.to_s && (now_ms - row[:ts_ms]) <= win * 5
        end
        return tick_size if relevant.size < 2

        mids = relevant.map { |r| r[:mid] }
        span = mids.max - mids.min
        span > tick_size ? span : tick_size
      end

      def section
        s = @config.respond_to?(:orderflow_section) ? @config.orderflow_section : {}
        sec = s[:sweep]
        sec.is_a?(Hash) ? sec : {}
      end

      def min_levels
        section.fetch(:min_levels, DEFAULT_MIN_LEVELS).to_i
      end

      def window_ms
        Integer(section.fetch(:window_ms, DEFAULT_WINDOW_MS))
      rescue ArgumentError, TypeError
        DEFAULT_WINDOW_MS
      end

      def displacement_atr_mult
        BigDecimal(section.fetch(:displacement_atr_mult, DEFAULT_DISPLACEMENT_ATR_MULT).to_s)
      rescue ArgumentError, TypeError
        DEFAULT_DISPLACEMENT_ATR_MULT
      end

      def tick_size
        BigDecimal(section.fetch(:tick_size, DEFAULT_TICK).to_s)
      rescue ArgumentError, TypeError
        DEFAULT_TICK
      end
    end
  end
end
