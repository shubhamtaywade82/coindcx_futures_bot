# frozen_string_literal: true

require 'bigdecimal'

module CoindcxBot
  module Orderflow
    # Generic per-key state cache used to suppress repeated event emissions.
    #
    # Three primitives:
    #   * +emit_if_changed(key:, state:)+   — block runs only when stored state differs from cache
    #     (or +ttl_ms+ has elapsed). Used for bucket / categorical signals.
    #   * +emit_if_threshold_crossed(key:, value:, prev:, pct:)+ — block runs only when |Δ| / |prev|
    #     exceeds +pct+. +prev+ may be passed explicitly or pulled from cache.
    #   * +emit_if_cooled(key:, cooldown_ms:)+ — block runs only after +cooldown_ms+ since last emit.
    #
    # +fetch_state+ / +store_state+ expose raw access for callers that need bespoke gating
    # (e.g. wall removal grace) without re-implementing the timestamped cache.
    class EventDedup
      def initialize(clock: nil)
        @clock = clock || -> { (Time.now.to_f * 1000).to_i }
        @cache = {}
        @mutex = Mutex.new
      end

      def emit_if_changed(key:, state:, ttl_ms: nil)
        now = @clock.call
        @mutex.synchronize do
          entry = @cache[key]
          return false if entry && entry[:state] == state && (ttl_ms.nil? || (now - entry[:ts]) < ttl_ms)

          @cache[key] = { state: state, ts: now }
        end
        yield if block_given?
        true
      end

      def emit_if_threshold_crossed(key:, value:, prev:, pct:)
        now = @clock.call
        @mutex.synchronize do
          baseline = prev || @cache[key]&.dig(:value)
          return false if baseline && baseline != 0 && (((value - baseline).abs / baseline.abs) < pct)

          @cache[key] = { value: value, ts: now }
        end
        yield if block_given?
        true
      end

      def emit_if_cooled(key:, cooldown_ms:)
        now = @clock.call
        @mutex.synchronize do
          entry = @cache[key]
          return false if entry && (now - entry[:ts]) < cooldown_ms

          @cache[key] = { ts: now }
        end
        yield if block_given?
        true
      end

      def fetch_state(key)
        @mutex.synchronize { @cache[key]&.dup }
      end

      def store_state(key, **fields)
        now = @clock.call
        @mutex.synchronize { @cache[key] = fields.merge(ts: now) }
      end

      def now_ms
        @clock.call
      end

      def reset!
        @mutex.synchronize { @cache.clear }
      end
    end

    # Tracks per-(pair, source, side, price-band) wall state and emits +liquidity.wall.detected+ /
    # +liquidity.wall.removed+ only on meaningful transitions.
    #
    # Transitions:
    #   * detected — wall not previously cached
    #   * detected — cached size moved >= +size_change_pct+ vs last emitted size
    #   * removed  — wall absent for at least +removal_grace_ms+ across consecutive book updates
    #
    # The caller iterates +process+ for every snapshot; the block yields +[kind, payload]+ for
    # each emission and the return value indicates whether a per-wall change occurred (so the
    # caller can decide whether to publish the aggregate +orderflow_walls+ event).
    class WallDedup
      DEFAULT_PRICE_BAND_TICKS = 1
      DEFAULT_TICK_SIZE        = '0.01'
      DEFAULT_SIZE_CHANGE_PCT  = 0.25
      DEFAULT_REMOVAL_GRACE_MS = 500

      def initialize(config:, clock: nil)
        @config = config
        @clock  = clock || -> { (Time.now.to_f * 1000).to_i }
        @cache  = {}
        @mutex  = Mutex.new
      end

      def process(pair:, source:, walls:, ts_ms:, &)
        ts = ts_ms || @clock.call
        seen, detected = ingest_walls(pair, source, walls, ts, &)
        removed = process_removals(pair, source, seen, ts, &)
        detected || removed
      end

      def reset!
        @mutex.synchronize { @cache.clear }
      end

      private

      def ingest_walls(pair, source, walls, ts, &block)
        seen = {}
        any_change = false
        Array(walls).each do |wall|
          band = price_band(wall[:price])
          key = wall_key(pair, source, wall[:side], band)
          seen[key] = true
          changed = upsert_wall(key, pair, source, wall, band, ts, &block)
          any_change ||= changed
        end
        [seen, any_change]
      end

      def upsert_wall(key, pair, source, wall, band, ts)
        emit_payload = nil
        @mutex.synchronize do
          entry = @cache[key]
          if entry.nil?
            @cache[key] = build_entry(wall, band, first_seen: ts, last_seen: ts)
            emit_payload = payload_for(pair, source, wall, band, ts)
          elsif size_changed?(entry[:emitted_size], wall[:size])
            @cache[key] = build_entry(wall, band, first_seen: entry[:first_seen_ts], last_seen: ts)
            emit_payload = payload_for(pair, source, wall, band, ts)
          else
            @cache[key] = entry.merge(
              size: wall[:size], score: wall[:score], last_seen_ts: ts, pending_removal_at: nil
            )
          end
        end

        return false unless emit_payload

        yield :detected, emit_payload
        true
      end

      def process_removals(pair, source, seen, ts)
        any_removal = false
        prefix = "#{pair}|#{source}|"
        @mutex.synchronize { @cache.keys.dup }.each do |key|
          next unless key.start_with?(prefix)
          next if seen[key]

          if (payload = stage_or_emit_removal(key, pair, source, ts))
            yield :removed, payload
            any_removal = true
          end
        end
        any_removal
      end

      def stage_or_emit_removal(key, pair, source, ts)
        @mutex.synchronize do
          entry = @cache[key]
          return nil unless entry

          if entry[:pending_removal_at].nil?
            @cache[key] = entry.merge(pending_removal_at: ts)
            return nil
          end

          return nil if (ts - entry[:pending_removal_at]) < removal_grace_ms

          @cache.delete(key)
          removal_payload(pair, source, entry, ts)
        end
      end

      def build_entry(wall, band, first_seen:, last_seen:)
        {
          side: wall[:side],
          band: band,
          price: wall[:price],
          size: wall[:size],
          score: wall[:score],
          emitted_size: wall[:size],
          first_seen_ts: first_seen,
          last_seen_ts: last_seen,
          pending_removal_at: nil,
        }
      end

      def payload_for(pair, source, wall, band, ts)
        {
          source: source,
          symbol: pair,
          pair: pair,
          side: wall[:side],
          price: wall[:price],
          price_band: band,
          size: wall[:size],
          score: wall[:score],
          ts: ts,
        }
      end

      def removal_payload(pair, source, entry, ts)
        {
          source: source,
          symbol: pair,
          pair: pair,
          side: entry[:side],
          price: entry[:price],
          price_band: entry[:band],
          last_size: entry[:size],
          first_seen_ts: entry[:first_seen_ts],
          ts: ts,
        }
      end

      def size_changed?(emitted, current)
        return true if emitted.nil?

        e = emitted.to_f
        return true if e.zero?

        ((current.to_f - e).abs / e) >= size_change_pct
      end

      def wall_key(pair, source, side, band)
        "#{pair}|#{source}|#{side}|#{band.to_s('F')}"
      end

      def price_band(price)
        tick = tick_size
        return BigDecimal(price.to_s) if tick <= 0

        step = tick * price_band_ticks
        return BigDecimal(price.to_s) if step <= 0

        (BigDecimal(price.to_s) / step).floor * step
      rescue ArgumentError, TypeError
        BigDecimal(price.to_s)
      end

      def section
        s = @config.respond_to?(:orderflow_section) ? @config.orderflow_section : {}
        sec = s.dig(:walls, :dedup)
        sec.is_a?(Hash) ? sec : {}
      end

      def price_band_ticks
        Integer(section.fetch(:price_band_ticks, DEFAULT_PRICE_BAND_TICKS))
      rescue ArgumentError, TypeError
        DEFAULT_PRICE_BAND_TICKS
      end

      def tick_size
        BigDecimal(section.fetch(:tick_size, DEFAULT_TICK_SIZE).to_s)
      rescue ArgumentError, TypeError
        BigDecimal(DEFAULT_TICK_SIZE)
      end

      def size_change_pct
        Float(section.fetch(:size_change_pct, DEFAULT_SIZE_CHANGE_PCT))
      rescue ArgumentError, TypeError
        DEFAULT_SIZE_CHANGE_PCT
      end

      def removal_grace_ms
        Integer(section.fetch(:removal_grace_ms, DEFAULT_REMOVAL_GRACE_MS))
      rescue ArgumentError, TypeError
        DEFAULT_REMOVAL_GRACE_MS
      end
    end

    # Routes engine-detected signals through dedup helpers before reaching the bus.
    # Imbalance: bucket-flip + magnitude-cross + min-emit-interval floor.
    # Walls: per-band state cache (size change / removal grace) plus aggregate gating.
    # All other signals pass straight through to preserve current consumers.
    class SignalPublisher
      DEFAULT_IMBALANCE_MIN_EMIT_INTERVAL_MS = 500
      DEFAULT_IMBALANCE_MAGNITUDE_PCT        = 0.5

      def initialize(bus:, config:)
        @bus            = bus
        @config         = config
        @imbalance_dedup = EventDedup.new
        @wall_dedup     = WallDedup.new(config: config)
      end

      def publish(signal, source:, ts_ms:)
        case signal[:type]
        when :imbalance then publish_imbalance(signal, source)
        when :walls     then publish_walls(signal, source, ts_ms)
        else
          @bus.publish(:"orderflow_#{signal[:type]}", signal)
        end
      end

      def sweep_orphaned_walls(pair:, source:, ts_ms:)
        return unless dedup_enabled?(:walls, source)

        wall_ts = ts_ms || (Time.now.to_f * 1000).to_i
        @wall_dedup.process(pair: pair, source: source, walls: [], ts_ms: wall_ts) do |kind, payload|
          publish_wall_event(kind, payload)
        end
      end

      private

      def publish_imbalance(payload, source)
        unless dedup_enabled?(:imbalance, source)
          @bus.publish(:orderflow_imbalance, payload)
          return
        end

        key  = "imbalance|#{payload[:pair]}|#{source}"
        now  = payload[:ts] || @imbalance_dedup.now_ms
        prev = @imbalance_dedup.fetch_state(key)
        return unless imbalance_emit?(prev: prev, bias: payload[:bias], value: payload[:value].to_f, now: now)

        @imbalance_dedup.store_state(key, bias: payload[:bias], value: payload[:value].to_f, last_emit_ms: now)
        @bus.publish(:orderflow_imbalance, payload)
      end

      def imbalance_emit?(prev:, bias:, value:, now:)
        return true if prev.nil?

        interval = imbalance_min_emit_interval_ms
        return false if interval.positive? && (now - prev[:last_emit_ms].to_i) < interval

        return true if prev[:bias] != bias

        magnitude_crossed?(prev[:value].to_f, value, imbalance_magnitude_pct)
      end

      def magnitude_crossed?(prev_value, current_value, pct)
        return true if prev_value.zero?

        ((current_value - prev_value).abs / prev_value.abs) >= pct
      end

      def publish_walls(payload, source, ts_ms)
        unless dedup_enabled?(:walls, source)
          @bus.publish(:orderflow_walls, payload)
          publish_legacy_wall_events(payload, ts_ms, source)
          return
        end

        wall_ts = ts_ms || (Time.now.to_f * 1000).to_i
        changed = @wall_dedup.process(pair: payload[:pair], source: source, walls: enumerate_walls(payload), ts_ms: wall_ts) do |kind, wall_payload|
          publish_wall_event(kind, wall_payload)
        end

        @bus.publish(:orderflow_walls, payload) if changed
      end

      def publish_wall_event(kind, payload)
        case kind
        when :detected then @bus.publish(:'liquidity.wall.detected', payload)
        when :removed  then @bus.publish(:'liquidity.wall.removed', payload)
        end
      end

      def enumerate_walls(payload)
        threshold = payload[:threshold]
        bids = Array(payload[:bid_walls]).map { |w| wall_record(:bid, w, threshold) }
        asks = Array(payload[:ask_walls]).map { |w| wall_record(:ask, w, threshold) }
        bids + asks
      end

      def wall_record(side, wall, threshold)
        { side: side, price: wall[:price], size: wall[:size], score: wall_score(wall[:size], threshold) }
      end

      def wall_score(size, threshold)
        thr_bd = BigDecimal(threshold.to_s)
        return 0.0 unless thr_bd.positive?

        (BigDecimal(size.to_s) / thr_bd).round(4).to_f
      rescue ArgumentError, TypeError
        0.0
      end

      def publish_legacy_wall_events(signal, ts_ms, source)
        thr = BigDecimal(signal[:threshold].to_s)
        wall_ts = ts_ms || (Time.now.to_f * 1000).to_i
        emit_legacy_side(:bid, Array(signal[:bid_walls]), pair: signal[:pair], source: signal[:source] || source, threshold: thr, ts: wall_ts)
        emit_legacy_side(:ask, Array(signal[:ask_walls]), pair: signal[:pair], source: signal[:source] || source, threshold: thr, ts: wall_ts)
      end

      def emit_legacy_side(side, walls, pair:, source:, threshold:, ts:)
        walls.each do |w|
          size_bd = BigDecimal(w[:size].to_s)
          score_f = threshold.positive? ? (size_bd / threshold).round(4).to_f : 0.0
          @bus.publish(
            :'liquidity.wall.detected',
            { source: source, symbol: pair, pair: pair, side: side,
              price: w[:price], size: w[:size], score: score_f, ts: ts }
          )
        end
      end

      def dedup_enabled?(name, source)
        sec = section.dig(name, :dedup)
        return !!sec[:enabled] if sec.is_a?(Hash) && sec.key?(:enabled)

        source.to_sym == :binance
      end

      def imbalance_min_emit_interval_ms
        sec = section.dig(:imbalance, :dedup) || {}
        Integer(sec.fetch(:min_emit_interval_ms, DEFAULT_IMBALANCE_MIN_EMIT_INTERVAL_MS))
      rescue ArgumentError, TypeError
        DEFAULT_IMBALANCE_MIN_EMIT_INTERVAL_MS
      end

      def imbalance_magnitude_pct
        sec = section.dig(:imbalance, :dedup) || {}
        Float(sec.fetch(:magnitude_change_pct, DEFAULT_IMBALANCE_MAGNITUDE_PCT))
      rescue ArgumentError, TypeError
        DEFAULT_IMBALANCE_MAGNITUDE_PCT
      end

      def section
        @config.respond_to?(:orderflow_section) ? @config.orderflow_section : {}
      end
    end

    # Bus wrapper that gates detector-emitted +liquidity.*+ events with per-key cooldowns.
    # Imbalance and walls dedup live in +Engine+ (bespoke transition logic). This wrapper
    # keeps sweep/iceberg/void emissions noise-free without touching detector internals.
    #
    # Source-based default: +:binance+ payloads dedup; +:coindcx+ payloads pass straight through
    # for backward compatibility. Per-event +dedup.enabled+ override wins when set.
    class DedupPublisher
      DEFAULT_COOLDOWN_MS = 1000

      EVENT_SECTIONS = {
        'liquidity.sweep.detected': :sweep,
        'liquidity.iceberg.suspected': :iceberg,
        'liquidity.void.detected': :void,
      }.freeze

      def initialize(bus:, config:, clock: nil)
        @bus    = bus
        @config = config
        @dedup  = EventDedup.new(clock: clock)
      end

      def publish(event, payload = nil)
        return @bus.publish(event, payload) unless cooled_event?(event)
        return @bus.publish(event, payload) unless dedup_for?(event, payload)

        section_name = EVENT_SECTIONS.fetch(event)
        @dedup.emit_if_cooled(key: dedup_key(event, payload), cooldown_ms: cooldown_ms_for(section_name)) do
          @bus.publish(event, payload)
        end
      end

      def subscribe(event, &)
        @bus.subscribe(event, &)
        self
      end

      private

      def cooled_event?(event)
        EVENT_SECTIONS.key?(event)
      end

      def dedup_for?(event, payload)
        section_name = EVENT_SECTIONS.fetch(event)
        sec = section_for(section_name)
        return !!sec[:enabled] if sec.is_a?(Hash) && sec.key?(:enabled)

        source_for(payload) == :binance
      end

      def source_for(payload)
        return :coindcx unless payload.is_a?(Hash)

        (payload[:source] || :coindcx).to_sym
      end

      def cooldown_ms_for(section_name)
        Integer(section_for(section_name).fetch(:cooldown_ms, DEFAULT_COOLDOWN_MS))
      rescue ArgumentError, TypeError
        DEFAULT_COOLDOWN_MS
      end

      def section_for(name)
        s = @config.respond_to?(:orderflow_section) ? @config.orderflow_section : {}
        sec = s.dig(name, :dedup)
        sec.is_a?(Hash) ? sec : {}
      rescue StandardError
        {}
      end

      def dedup_key(event, payload)
        return event.to_s unless payload.is_a?(Hash)

        case event
        when :'liquidity.sweep.detected'
          "sweep|#{payload[:pair]}|#{payload[:side]}"
        when :'liquidity.iceberg.suspected'
          "iceberg|#{payload[:pair]}|#{payload[:side]}|#{payload[:price]}"
        when :'liquidity.void.detected'
          "void|#{payload[:pair]}|#{payload[:side]}|#{payload[:void_start]}|#{payload[:void_end]}"
        else
          event.to_s
        end
      end
    end
  end
end
