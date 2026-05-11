# frozen_string_literal: true

require 'bigdecimal'

module CoindcxBot
  module Orderflow
    # Thread-safe cache of Binance-sourced liquidity microstructure, fed from the shared EventBus.
    class LiquidityContextStore
      WALL_TTL_MS = 60_000
      SWEEP_RING_MAX = 8
      ICEBERG_RING_MAX = 5
      VOID_RING_MAX = 4
      ZONE_MAX_PER_SIDE = 16

      def initialize(bus:, clock: nil, divergence_lookup: nil)
        @bus = bus
        @clock = clock || -> { (Time.now.to_f * 1000).to_i }
        @divergence_lookup = divergence_lookup
        @mutex = Mutex.new
        @by_pair = {}
        wire_subscriptions!
      end

      def clear_pair(pair)
        p = pair.to_s
        @mutex.synchronize { @by_pair.delete(p) }
      end

      # Deep-copied snapshot for +pair+ (BigDecimal prices / numeric fields where applicable).
      def snapshot(pair)
        p = pair.to_s
        base = @mutex.synchronize { @by_pair[p] ? duplicate_state(@by_pair[p]) : empty_state }
        div = @divergence_lookup&.call(p)
        base[:divergence] = normalize_divergence(div)
        deep_immutable_hash(base)
      end

      private

      def empty_state
        {
          active_walls: { bid: [], ask: [] },
          recent_sweeps: [],
          recent_icebergs: [],
          imbalance: nil,
          confirmed_zones: { bid: [], ask: [] },
          voids: { bid: [], ask: [] },
          last_touch_ms: nil
        }
      end

      def wire_subscriptions!
        @bus.subscribe(:orderflow_imbalance) { |ev| on_imbalance(ev) }
        @bus.subscribe(:'liquidity.wall.detected') { |ev| on_wall_detected(ev) }
        @bus.subscribe(:'liquidity.wall.removed') { |ev| on_wall_removed(ev) }
        @bus.subscribe(:'liquidity.sweep.detected') { |ev| on_sweep(ev) }
        @bus.subscribe(:'liquidity.iceberg.suspected') { |ev| on_iceberg(ev) }
        @bus.subscribe(:'liquidity.void.detected') { |ev| on_void(ev) }
        @bus.subscribe(:'liquidity.zone.confirmed') { |ev| on_zone(ev) }
      end

      def binance?(payload)
        return false unless payload.is_a?(Hash)

        (payload[:source] || :coindcx).to_sym == :binance
      end

      def pair_from(payload)
        (payload[:pair] || payload[:symbol]).to_s
      end

      def now_ms
        @clock.call.to_i
      end

      def state_for(pair_s)
        @by_pair[pair_s] ||= empty_state
      end

      # Uses the event timestamp when present so +context_age+ reflects last Binance signal time (not local receive order).
      def touch!(st, event_ts_ms = nil)
        et = event_ts_ms.nil? ? nil : Integer(event_ts_ms)
        t = et&.positive? ? et : now_ms
        st[:last_touch_ms] = t
        t
      end

      def on_imbalance(ev)
        return unless binance?(ev)

        pair_s = pair_from(ev)
        return if pair_s.empty?

        @mutex.synchronize do
          st = state_for(pair_s)
          ts = Integer(ev[:ts] || now_ms)
          st[:imbalance] = {
            bucket: ev[:bias].to_sym,
            value: BigDecimal(ev[:value].to_s),
            ts: ts
          }
          touch!(st, ts)
        end
      end

      def on_wall_detected(ev)
        return unless binance?(ev)

        pair_s = pair_from(ev)
        return if pair_s.empty?

        side = ev[:side].to_s.to_sym
        return unless %i[bid ask].include?(side)

        price = BigDecimal(ev[:price].to_s)
        size = BigDecimal(ev[:size].to_s)
        score = BigDecimal(ev[:score].to_s)
        ts = Integer(ev[:ts] || now_ms)
        band = ev[:price_band] ? BigDecimal(ev[:price_band].to_s) : price
        key = wall_key(side, band)

        @mutex.synchronize do
          st = state_for(pair_s)
          walls = wall_map(st)
          walls[key] = { side: side, price: price, size: size, score: score, ts_ms: ts, band: band }
          prune_walls_unlocked!(st, now_ms)
          touch!(st, ts)
        end
      end

      def on_wall_removed(ev)
        return unless binance?(ev)

        pair_s = pair_from(ev)
        return if pair_s.empty?

        side = ev[:side].to_s.to_sym
        band = ev[:price_band] ? BigDecimal(ev[:price_band].to_s) : BigDecimal(ev[:price].to_s)
        key = wall_key(side, band)

        rm_ts = Integer(ev[:ts] || now_ms)
        @mutex.synchronize do
          st = state_for(pair_s)
          wall_map(st).delete(key)
          touch!(st, rm_ts)
        end
      end

      def wall_map(st)
        st[:wall_index] ||= {}
      end

      def wall_key(side, band)
        "#{side}:#{band.to_s('F')}"
      end

      def on_sweep(ev)
        return unless binance?(ev)

        pair_s = pair_from(ev)
        return if pair_s.empty?

        row = {
          side: ev[:side].to_s.to_sym,
          ts: Integer(ev[:ts] || now_ms),
          levels_swept: Integer(ev[:levels_swept] || 0),
          notional: ev[:notional].is_a?(BigDecimal) ? ev[:notional] : BigDecimal(ev[:notional].to_s)
        }

        @mutex.synchronize do
          st = state_for(pair_s)
          ring = st[:recent_sweeps]
          ring << row
          ring.shift while ring.size > SWEEP_RING_MAX
          touch!(st, row[:ts])
        end
      end

      def on_iceberg(ev)
        return unless binance?(ev)

        pair_s = pair_from(ev)
        return if pair_s.empty?

        row = {
          price: BigDecimal(ev[:price].to_s),
          side: ev[:side].to_s.to_sym,
          score: ev[:score].is_a?(BigDecimal) ? ev[:score] : BigDecimal(ev[:score].to_s),
          ts: Integer(ev[:ts] || now_ms)
        }

        @mutex.synchronize do
          st = state_for(pair_s)
          ring = st[:recent_icebergs]
          ring << row
          ring.shift while ring.size > ICEBERG_RING_MAX
          touch!(st, row[:ts])
        end
      end

      def on_void(ev)
        return unless binance?(ev)

        pair_s = pair_from(ev)
        return if pair_s.empty?

        side = ev[:side].to_s.to_sym
        return unless %i[bid ask].include?(side)

        row = {
          void_start: BigDecimal(ev[:void_start].to_s),
          void_end: BigDecimal(ev[:void_end].to_s),
          ts: Integer(ev[:ts] || now_ms)
        }

        @mutex.synchronize do
          st = state_for(pair_s)
          ring = st[:voids][side]
          ring << row
          ring.shift while ring.size > VOID_RING_MAX
          touch!(st, row[:ts])
        end
      end

      def on_zone(ev)
        return unless binance?(ev)

        pair_s = pair_from(ev)
        return if pair_s.empty?

        side = ev[:side].to_s.to_sym
        return unless %i[bid ask].include?(side)

        band = BigDecimal(ev[:price_band].to_s)
        row = { price_band: band, ts: Integer(ev[:ts] || now_ms) }

        @mutex.synchronize do
          st = state_for(pair_s)
          z = st[:confirmed_zones][side]
          z << row
          z.shift while z.size > ZONE_MAX_PER_SIDE
          touch!(st, row[:ts])
        end
      end

      def prune_walls_unlocked!(st, t)
        wall_map(st).delete_if { |_, w| (t - w[:ts_ms]) > WALL_TTL_MS }
      end

      def duplicate_imbalance(im)
        return nil unless im

        { bucket: im[:bucket], value: im[:value].dup, ts: im[:ts] }
      end

      def duplicate_state(st)
        t = now_ms
        prune_walls_unlocked!(st, t) if st[:wall_index]

        bid_rows = []
        ask_rows = []
        wall_map(st).each_value do |w|
          age = t - w[:ts_ms]
          row = { price: w[:price].dup, size: w[:size].dup, score: w[:score].dup, age_ms: age }
          (w[:side] == :bid ? bid_rows : ask_rows) << row
        end

        {
          active_walls: { bid: bid_rows, ask: ask_rows },
          recent_sweeps: st[:recent_sweeps].map(&:dup),
          recent_icebergs: st[:recent_icebergs].map do |r|
            { price: r[:price].dup, side: r[:side], score: r[:score].dup, ts: r[:ts] }
          end,
          imbalance: duplicate_imbalance(st[:imbalance]),
          confirmed_zones: {
            bid: st[:confirmed_zones][:bid].map { |z| { price_band: z[:price_band].dup, ts: z[:ts] } },
            ask: st[:confirmed_zones][:ask].map { |z| { price_band: z[:price_band].dup, ts: z[:ts] } }
          },
          voids: {
            bid: st[:voids][:bid].map { |v| { void_start: v[:void_start].dup, void_end: v[:void_end].dup, ts: v[:ts] } },
            ask: st[:voids][:ask].map { |v| { void_start: v[:void_start].dup, void_end: v[:void_end].dup, ts: v[:ts] } }
          },
          last_touch_ms: st[:last_touch_ms]
        }
      end

      def normalize_divergence(div)
        return { status: :unset, bps: nil, age_ms: nil } unless div.is_a?(Hash)

        {
          status: (div[:status] || :unset).to_sym,
          bps: div[:bps].nil? ? nil : BigDecimal(div[:bps].to_s),
          age_ms: div[:age_ms].nil? ? nil : Integer(div[:age_ms])
        }
      end

      def deep_immutable_hash(obj)
        case obj
        when Hash
          obj.transform_values { |v| deep_immutable_hash(v) }.freeze
        when Array
          obj.map { |v| deep_immutable_hash(v) }.freeze
        else
          obj
        end
      end
    end
  end
end
