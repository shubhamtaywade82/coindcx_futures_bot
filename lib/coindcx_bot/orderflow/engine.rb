# frozen_string_literal: true

require_relative 'order_book_store'
require_relative 'absorption_tracker'

module CoindcxBot
  module Orderflow
    # Stateful, event-driven orderflow engine.
    #
    # Converts raw WS L2 snapshots into deterministic signals and publishes
    # them on the shared EventBus.  All detection is diff-based — static
    # snapshots are never used as standalone signals.
    #
    # Signals published (EventBus event → payload):
    #   :orderflow_imbalance        — { pair, value, bias, depth }
    #   :orderflow_walls            — { pair, bid_walls, ask_walls, threshold }
    #   :orderflow_liquidity_shift  — { pair, events: [{type, price, size}] }
    #   :orderflow_spoof_activity   — { pair, events: [{side, price, size, action, dwell_seconds}] }
    #   :orderflow_absorption       — { pair, price, volume, range_pct }
    class Engine
      DEFAULT_IMBALANCE_DEPTH          = 5
      DEFAULT_WALL_MULTIPLIER          = 3.0
      DEFAULT_SPOOF_THRESHOLD          = 10_000.0
      DEFAULT_SPOOF_MAX_DWELL_SECONDS  = 60.0    # candidate expires (executed, not spoofed)
      DEFAULT_IMBALANCE_SPIKE_THRESHOLD = 0.25

      def initialize(bus:, config:, logger: nil)
        @bus                = bus
        @config             = config
        @logger             = logger
        @store              = OrderBookStore.new
        @absorption         = AbsorptionTracker.new(config: config)
        @spoof_candidates   = Hash.new { |h, k| h[k] = {} } # pair => { price_str => {side, size, seen_at} }
        @spoof_mutex        = Mutex.new
      end

      # Entry point called from the WS order-book callback (WS thread).
      # Runs all detectors, publishes non-nil signals to EventBus.
      def on_book_update(pair:, bids:, asks:)
        diff = @store.update!(pair: pair, bids: bids, asks: asks)
        snap = @store.snapshot_for(pair)

        signals = []
        signals << detect_imbalance(pair, snap)
        signals << detect_walls(pair, snap)
        signals << detect_liquidity_shift(pair, diff)
        signals << detect_spoof(pair, diff)
        signals << @absorption.on_book_update(pair: pair, snap: snap, diff: diff)
        signals.compact!

        publish(signals)
      rescue StandardError => e
        @logger&.warn("[orderflow:engine] #{pair}: #{e.message}")
      end

      private

      # ── Imbalance ───────────────────────────────────────────────────────────
      # imbalance = (bid_vol − ask_vol) / (bid_vol + ask_vol)
      # Range: −1.0 (fully ask-heavy) … +1.0 (fully bid-heavy)

      def detect_imbalance(pair, snap)
        depth   = imbalance_depth
        bid_vol = snap[:bids].sort_by { |p, _| -p.to_f }.first(depth).sum { |_, s| s }
        ask_vol = snap[:asks].sort_by { |p, _|  p.to_f }.first(depth).sum { |_, s| s }
        total   = bid_vol + ask_vol
        return nil if total.zero?

        value = (bid_vol - ask_vol) / total
        bias  =
          if value > imbalance_spike_threshold
            :bullish
          elsif value < -imbalance_spike_threshold
            :bearish
          else
            :neutral
          end

        { type: :imbalance, pair: pair, value: value.round(4), bias: bias, depth: depth }
      end

      # ── Walls ────────────────────────────────────────────────────────────────
      # Wall = level whose size exceeds (mean_size × wall_multiplier).
      # Dynamic threshold adapts to the current book; avoids hard-coded notional values.

      def detect_walls(pair, snap)
        all_sizes = snap[:bids].values + snap[:asks].values
        return nil if all_sizes.empty?

        avg       = all_sizes.sum / all_sizes.size.to_f
        threshold = avg * wall_multiplier

        bid_walls = snap[:bids].select { |_, s| s > threshold }.map { |p, s| { price: p, size: s } }
        ask_walls = snap[:asks].select { |_, s| s > threshold }.map { |p, s| { price: p, size: s } }
        return nil if bid_walls.empty? && ask_walls.empty?

        { type: :walls, pair: pair, bid_walls: bid_walls, ask_walls: ask_walls, threshold: threshold.round(2) }
      end

      # ── Liquidity shift ──────────────────────────────────────────────────────
      # Emit any level that was added or removed vs the previous snapshot.
      # ask_pull (large ask removed) → potential bullish breakout.
      # bid_pull (large bid removed) → potential breakdown.

      def detect_liquidity_shift(pair, diff)
        events = []

        diff.ask_removed.each { |p, s| events << { type: :ask_pull, price: p, size: s } }
        diff.bid_removed.each { |p, s| events << { type: :bid_pull, price: p, size: s } }
        diff.ask_added.each   { |p, s| events << { type: :ask_add,  price: p, size: s } }
        diff.bid_added.each   { |p, s| events << { type: :bid_add,  price: p, size: s } }

        return nil if events.empty?

        { type: :liquidity_shift, pair: pair, events: events }
      end

      # ── Spoof detection ──────────────────────────────────────────────────────
      # Stage 1 (add):   large order appears → remember it as a candidate.
      # Stage 2 (remove): candidate vanishes before DEFAULT_SPOOF_MAX_DWELL expires → suspicious.
      # Candidates that persist (actually executed / moved slowly) expire after 60 s.

      def detect_spoof(pair, diff)
        threshold = spoof_threshold
        now       = Time.now.to_f
        suspicious = []

        @spoof_mutex.synchronize do
          candidates = @spoof_candidates[pair]

          # Register newly-added large levels as candidates
          diff.bid_added.each do |price, size|
            candidates[price] = { side: :bid, size: size, seen_at: now } if size >= threshold
          end
          diff.ask_added.each do |price, size|
            candidates[price] = { side: :ask, size: size, seen_at: now } if size >= threshold
          end

          # Check whether a known candidate just disappeared
          (diff.bid_removed.merge(diff.ask_removed)).each do |price, size|
            next unless size >= threshold
            next unless (c = candidates.delete(price))

            suspicious << {
              side:          c[:side],
              price:         price,
              size:          size,
              action:        :removed,
              dwell_seconds: (now - c[:seen_at]).round(2)
            }
          end

          # Expire stale candidates: they likely executed (not spoofed)
          candidates.reject! { |_, v| now - v[:seen_at] > spoof_max_dwell }
        end

        return nil if suspicious.empty?

        { type: :spoof_activity, pair: pair, events: suspicious }
      end

      # ── EventBus publish ─────────────────────────────────────────────────────

      def publish(signals)
        signals.each do |signal|
          event = :"orderflow_#{signal[:type]}"
          @bus.publish(event, signal)
        end
      end

      # ── Config helpers ────────────────────────────────────────────────────────

      def section
        @config.respond_to?(:orderflow_section) ? @config.orderflow_section : {}
      end

      def imbalance_depth
        section.fetch(:imbalance_depth, DEFAULT_IMBALANCE_DEPTH).to_i
      end

      def imbalance_spike_threshold
        Float(section.fetch(:imbalance_spike_threshold, DEFAULT_IMBALANCE_SPIKE_THRESHOLD))
      rescue ArgumentError, TypeError
        DEFAULT_IMBALANCE_SPIKE_THRESHOLD
      end

      def wall_multiplier
        Float(section.fetch(:wall_multiplier, DEFAULT_WALL_MULTIPLIER))
      rescue ArgumentError, TypeError
        DEFAULT_WALL_MULTIPLIER
      end

      def spoof_threshold
        Float(section.fetch(:spoof_threshold, DEFAULT_SPOOF_THRESHOLD))
      rescue ArgumentError, TypeError
        DEFAULT_SPOOF_THRESHOLD
      end

      def spoof_max_dwell
        Float(section.fetch(:spoof_max_dwell_seconds, DEFAULT_SPOOF_MAX_DWELL_SECONDS))
      rescue ArgumentError, TypeError
        DEFAULT_SPOOF_MAX_DWELL_SECONDS
      end
    end
  end
end
