# frozen_string_literal: true

require_relative 'order_book_store'
require_relative 'absorption_tracker'
require_relative 'recorder'

module CoindcxBot
  module Orderflow
    # Stateful, event-driven orderflow engine.
    #
    # Converts raw WS L2 snapshots and trades into deterministic signals and publishes
    # them on the shared EventBus.
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
      DEFAULT_SPOOF_MAX_DWELL_SECONDS  = 60.0
      DEFAULT_IMBALANCE_SPIKE_THRESHOLD = 0.25

      def initialize(bus:, config:, logger: nil)
        @bus                = bus
        @config             = config
        @logger             = logger
        @store              = OrderBookStore.new
        @absorption         = AbsorptionTracker.new(config: config)
        @recorder           = Recorder.new(config: config, logger: logger)
        @spoof_candidates   = Hash.new { |h, k| h[k] = {} }
        @spoof_mutex        = Mutex.new
      end

      # Called from the WS trade callback.
      def on_trade(trade)
        @recorder.record_trade(trade)
        @absorption.on_trade(trade)
      rescue StandardError => e
        @logger&.warn("[orderflow:engine] trade error: #{e.message}")
      end

      # Called from the WS order-book callback.
      def on_book_update(pair:, bids:, asks:)
        @recorder.record_snapshot(pair, bids, asks)

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
        @logger&.warn("[orderflow:engine] book error #{pair}: #{e.message}")
      end

      def shutdown
        @recorder.close
      end

      private

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

      def detect_liquidity_shift(pair, diff)
        events = []
        diff.ask_removed.each { |p, s| events << { type: :ask_pull, price: p, size: s } }
        diff.bid_removed.each { |p, s| events << { type: :bid_pull, price: p, size: s } }
        diff.ask_added.each   { |p, s| events << { type: :ask_add,  price: p, size: s } }
        diff.bid_added.each   { |p, s| events << { type: :bid_add,  price: p, size: s } }
        return nil if events.empty?

        { type: :liquidity_shift, pair: pair, events: events }
      end

      def detect_spoof(pair, diff)
        threshold = spoof_threshold
        now       = Time.now.to_f
        suspicious = []

        @spoof_mutex.synchronize do
          candidates = @spoof_candidates[pair]
          diff.bid_added.each do |price, size|
            candidates[price] = { side: :bid, size: size, seen_at: now } if size >= threshold
          end
          diff.ask_added.each do |price, size|
            candidates[price] = { side: :ask, size: size, seen_at: now } if size >= threshold
          end

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
          candidates.reject! { |_, v| now - v[:seen_at] > spoof_max_dwell }
        end

        return nil if suspicious.empty?
        { type: :spoof_activity, pair: pair, events: suspicious }
      end

      def publish(signals)
        signals.each do |signal|
          event = :"orderflow_#{signal[:type]}"
          @bus.publish(event, signal)
        end
      end

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
