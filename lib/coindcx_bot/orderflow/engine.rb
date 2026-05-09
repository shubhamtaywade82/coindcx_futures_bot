# frozen_string_literal: true

require 'bigdecimal'

require_relative 'order_book_store'
require_relative 'absorption_tracker'
require_relative 'recorder'
require_relative 'sweep_detector'
require_relative 'iceberg_detector'
require_relative 'liquidity_void_detector'
require_relative 'liquidity_zone_tracker'

module CoindcxBot
  module Orderflow
    # Stateful, event-driven orderflow engine.
    #
    # Converts raw WS L2 snapshots and trades into deterministic signals and publishes
    # them on the shared EventBus.
    #
    # Signals published (EventBus event → payload):
    #   :orderflow_imbalance        — { pair, value, bias, depth, source }
    #   :orderflow_walls            — { pair, bid_walls, ask_walls, threshold, source }
    #   :orderflow_liquidity_shift  — { pair, events: [{type, price, size}], source }
    #   :orderflow_spoof_activity   — { pair, events: [{side, price, size, action, dwell_seconds}], source }
    #   :orderflow_absorption       — { pair, price, volume, range_pct, source }
    #
    # Optional domain events (when +orderflow.{sweep,iceberg,void,zones}.enabled: true+):
    #   :'liquidity.sweep.detected' | :'liquidity.iceberg.suspected' | :'liquidity.void.detected' | :'liquidity.zone.confirmed'
    #   :'liquidity.wall.detected' (per wall row, for zone tracker)
    class Engine
      DEFAULT_IMBALANCE_DEPTH          = 5
      DEFAULT_WALL_MULTIPLIER          = 3.0
      DEFAULT_SPOOF_THRESHOLD          = 10_000.0
      DEFAULT_SPOOF_MAX_DWELL_SECONDS  = 60.0
      DEFAULT_IMBALANCE_SPIKE_THRESHOLD = 0.25
      DEFAULT_LIQUIDITY_CLASSIFICATION_WINDOW_MS = 750.0
      DEFAULT_TRADE_THROUGH_VOLUME_RATIO = 0.6

      attr_reader :sweep_detector, :iceberg_detector

      def initialize(bus:, config:, logger: nil)
        @bus                = bus
        @config             = config
        @logger             = logger
        @store              = OrderBookStore.new
        @absorption         = AbsorptionTracker.new(config: config)
        @recorder           = Recorder.new(config: config, logger: logger)
        @spoof_candidates   = Hash.new { |h, k| h[k] = {} }
        @spoof_mutex        = Mutex.new
        @recent_trades      = Hash.new { |h, k| h[k] = [] }
        @trades_mutex       = Mutex.new
        @sweep_detector     = SweepDetector.new(bus: bus, config: config) if subsection_enabled?(:sweep)
        @iceberg_detector   = IcebergDetector.new(bus: bus, config: config) if subsection_enabled?(:iceberg)
        @void_detector      = LiquidityVoidDetector.new(bus: bus, config: config) if subsection_enabled?(:void)
        @zone_tracker       = LiquidityZoneTracker.new(bus: bus, config: config) if subsection_enabled?(:zones)
      end

      # Called from the WS trade callback.
      def on_trade(trade)
        trade = trade.merge(source: trade[:source] || :coindcx)
        @recorder.record_trade(trade)
        store_trade_for_liquidity_classification(trade)
        @absorption.on_trade(trade)
        @iceberg_detector&.on_trade(trade)
      rescue StandardError => e
        @logger&.warn("[orderflow:engine] trade error: #{e.message}")
      end

      # Called from the WS order-book callback.
      def on_book_update(pair:, bids:, asks:, source: :coindcx, ts: nil)
        ts_ms = normalize_book_ts_ms(ts)

        prev_snap = @store.snapshot_for(pair)
        @recorder.record_snapshot(pair, bids, asks)

        diff = @store.update!(pair: pair, bids: bids, asks: asks)
        snap = @store.snapshot_for(pair)

        @sweep_detector&.feed_coindcx_book(pair: pair, source: source, prev_snap: prev_snap, diff: diff, snap: snap)
        @iceberg_detector&.feed_coindcx_levels(
          pair: pair, source: source, prev_side: prev_snap[:bids], new_side: snap[:bids], side: :bid, ts_ms: ts_ms
        )
        @iceberg_detector&.feed_coindcx_levels(
          pair: pair, source: source, prev_side: prev_snap[:asks], new_side: snap[:asks], side: :ask, ts_ms: ts_ms
        )
        @void_detector&.on_book(pair: pair, bids: snap[:bids], asks: snap[:asks], source: source, ts_ms: ts_ms)

        signals = []
        signals << detect_imbalance(pair, snap)
        signals << detect_walls(pair, snap)
        signals << detect_liquidity_shift(pair, diff)
        signals << detect_spoof(pair, diff)
        signals << @absorption.on_book_update(pair: pair, snap: snap, diff: diff, source: source)
        signals.compact!

        publish(signals, ts_ms: ts_ms, source: source)
      rescue StandardError => e
        @logger&.warn("[orderflow:engine] book error #{pair}: #{e.message}")
      end

      def shutdown
        @recorder.close
      end

      private

      def subsection_enabled?(name)
        sec = section[name]
        sec.is_a?(Hash) && sec[:enabled] == true
      end

      def normalize_book_ts_ms(ts)
        return (Time.now.to_f * 1000).to_i if ts.nil?

        t = ts.to_i
        t > 1_000_000_000_000 ? t : (ts.to_f * 1000).to_i
      end

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
        diff.ask_removed.each do |price, size|
          events << passive_liquidity_event(
            event_type: :ask_pull,
            pair: pair,
            price: price,
            size: size,
            timestamp: diff.timestamp
          )
        end
        diff.bid_removed.each do |price, size|
          events << passive_liquidity_event(
            event_type: :bid_pull,
            pair: pair,
            price: price,
            size: size,
            timestamp: diff.timestamp
          )
        end
        diff.ask_reduced.each do |price, size|
          events << passive_liquidity_event(
            event_type: :ask_reduce,
            pair: pair,
            price: price,
            size: size,
            timestamp: diff.timestamp
          )
        end
        diff.bid_reduced.each do |price, size|
          events << passive_liquidity_event(
            event_type: :bid_reduce,
            pair: pair,
            price: price,
            size: size,
            timestamp: diff.timestamp
          )
        end
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

      def publish(signals, ts_ms:, source:)
        signals.each do |signal|
          enriched = signal.merge(source: signal[:source] || source)
          enriched[:ts] = ts_ms if ts_ms
          event = :"orderflow_#{enriched[:type]}"
          @bus.publish(event, enriched)
          publish_wall_liquidity_events(enriched, ts_ms, source) if enriched[:type] == :walls
        end
      end

      def publish_wall_liquidity_events(signal, ts_ms, source)
        src = signal[:source] || source
        pair = signal[:pair]
        thr = BigDecimal(signal[:threshold].to_s)
        wall_ts = ts_ms || (Time.now.to_f * 1000).to_i

        Array(signal[:bid_walls]).each do |w|
          size_bd = BigDecimal(w[:size].to_s)
          score_f = thr.positive? ? (size_bd / thr).round(4).to_f : 0.0
          @bus.publish(
            :'liquidity.wall.detected',
            {
              source: src,
              symbol: pair,
              pair: pair,
              side: :bid,
              price: w[:price],
              size: w[:size],
              score: score_f,
              ts: wall_ts
            }
          )
        end

        Array(signal[:ask_walls]).each do |w|
          size_bd = BigDecimal(w[:size].to_s)
          score_f = thr.positive? ? (size_bd / thr).round(4).to_f : 0.0
          @bus.publish(
            :'liquidity.wall.detected',
            {
              source: src,
              symbol: pair,
              pair: pair,
              side: :ask,
              price: w[:price],
              size: w[:size],
              score: score_f,
              ts: wall_ts
            }
          )
        end
      end

      def passive_liquidity_event(event_type:, pair:, price:, size:, timestamp:)
        classification = classify_passive_liquidity_change(
          pair: pair,
          event_type: event_type,
          price: price,
          size: size,
          timestamp: timestamp
        )

        { type: event_type, price: price, size: size, classification: classification }
      end

      def classify_passive_liquidity_change(pair:, event_type:, price:, size:, timestamp:)
        side = aggressive_trade_side_for(event_type)
        return :unknown unless side

        matched_volume = matching_aggressive_volume(
          pair: pair,
          side: side,
          price: price,
          timestamp: timestamp
        )

        return :trade_through if matched_volume >= (size.to_f * trade_through_volume_ratio)

        :cancel_or_requote
      end

      def aggressive_trade_side_for(event_type)
        event_name = event_type.to_s
        return :buy if event_name.start_with?('ask_')
        return :sell if event_name.start_with?('bid_')

        nil
      end

      def matching_aggressive_volume(pair:, side:, price:, timestamp:)
        target_price = Float(price)
        now_ms = timestamp.to_f * 1000.0
        cutoff_ms = now_ms - liquidity_classification_window_ms

        @trades_mutex.synchronize do
          trades = @recent_trades[pair]
          trades.sum do |trade|
            next 0.0 if trade[:side] != side
            next 0.0 if trade[:ts_ms] < cutoff_ms
            next 0.0 unless prices_match?(trade[:price], target_price)

            trade[:size]
          end
        end
      rescue ArgumentError, TypeError
        0.0
      end

      def prices_match?(left, right)
        (left.to_f - right.to_f).abs <= 1e-8
      end

      def store_trade_for_liquidity_classification(trade)
        pair = trade[:pair].to_s
        trade_entry = {
          price: Float(trade[:price]),
          size: Float(trade[:size]),
          side: normalize_trade_side(trade[:side]),
          ts_ms: normalize_trade_timestamp_ms(trade[:ts])
        }

        @trades_mutex.synchronize do
          entries = @recent_trades[pair]
          entries << trade_entry
          cutoff_ms = trade_entry[:ts_ms] - (liquidity_classification_window_ms * 4)
          entries.reject! { |row| row[:ts_ms] < cutoff_ms }
        end
      rescue ArgumentError, TypeError
        nil
      end

      def normalize_trade_side(raw_side)
        side = raw_side.to_s.downcase
        return :buy if side == 'buy'
        return :sell if side == 'sell'

        :unknown
      end

      def normalize_trade_timestamp_ms(raw_ts)
        ts = Float(raw_ts || 0.0)
        ts > 1_000_000_000_000 ? ts : ts * 1000.0
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

      def liquidity_classification_window_ms
        Float(section.fetch(:liquidity_classification_window_ms, DEFAULT_LIQUIDITY_CLASSIFICATION_WINDOW_MS))
      rescue ArgumentError, TypeError
        DEFAULT_LIQUIDITY_CLASSIFICATION_WINDOW_MS
      end

      def trade_through_volume_ratio
        Float(section.fetch(:trade_through_volume_ratio, DEFAULT_TRADE_THROUGH_VOLUME_RATIO))
      rescue ArgumentError, TypeError
        DEFAULT_TRADE_THROUGH_VOLUME_RATIO
      end
    end
  end
end
