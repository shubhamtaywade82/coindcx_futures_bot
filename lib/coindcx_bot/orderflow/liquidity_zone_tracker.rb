# frozen_string_literal: true

require 'bigdecimal'

module CoindcxBot
  module Orderflow
    # Clusters repeated +liquidity.wall.detected+ touches into persistent bands.
    class LiquidityZoneTracker
      DEFAULT_BAND_TICKS = 5
      DEFAULT_MIN_PERSISTENCE_MS = 30_000
      DEFAULT_EXPIRY_MS = 60_000

      def initialize(bus:, config:)
        @bus = bus
        @config = config
        @mutex = Mutex.new
        @zones = {} # key => state hash
        @bus.subscribe(:'liquidity.wall.detected') { |payload| on_wall(payload) }
      end

      private

      def on_wall(payload)
        pair = (payload[:symbol] || payload[:pair]).to_s
        source = (payload[:source] || :coindcx).to_sym
        raw_side = payload[:side]
        return if pair.empty? || raw_side.nil?

        side = raw_side.to_sym
        price = payload[:price]
        return if !price

        p = price.is_a?(BigDecimal) ? price : BigDecimal(price.to_s)
        ts = Integer(payload[:ts] || (Time.now.to_f * 1000))
        band = price_band(p)
        key = "#{pair}|#{source}|#{side}|#{band.to_s('F')}"

        @mutex.synchronize do
          prune_unlocked!(ts)
          z = @zones[key] ||= {
            pair: pair,
            source: source,
            side: side,
            band: band,
            first_seen: ts,
            last_seen: ts,
            touch_count: 0,
            confirmed: false
          }
          z[:last_seen] = ts
          z[:touch_count] += 1

          persistence = z[:last_seen] - z[:first_seen]
          if !z[:confirmed] && persistence >= min_persistence_ms
            z[:confirmed] = true
            @bus.publish(
              :'liquidity.zone.confirmed',
              {
                source: source,
                symbol: pair,
                side: side,
                price_band: band,
                persistence_ms: persistence,
                touch_count: z[:touch_count],
                ts: ts,
                pair: pair
              }
            )
          end
        end
      end

      def price_band(price)
        tick = tick_size
        return price if tick <= 0

        step = tick * band_ticks
        (price / step).floor(0) * step
      end

      def prune_unlocked!(now_ms)
        @zones.delete_if { |_, z| now_ms - z[:last_seen] > expiry_ms }
      end

      def section
        s = @config.respond_to?(:orderflow_section) ? @config.orderflow_section : {}
        sec = s[:zones]
        sec.is_a?(Hash) ? sec : {}
      end

      def band_ticks
        Integer(section.fetch(:band_ticks, DEFAULT_BAND_TICKS))
      rescue ArgumentError, TypeError
        DEFAULT_BAND_TICKS
      end

      def min_persistence_ms
        Integer(section.fetch(:min_persistence_ms, DEFAULT_MIN_PERSISTENCE_MS))
      rescue ArgumentError, TypeError
        DEFAULT_MIN_PERSISTENCE_MS
      end

      def expiry_ms
        Integer(section.fetch(:expiry_ms, DEFAULT_EXPIRY_MS))
      rescue ArgumentError, TypeError
        DEFAULT_EXPIRY_MS
      end

      def tick_size
        BigDecimal(section.fetch(:tick_size, '0.01').to_s)
      rescue ArgumentError, TypeError
        BigDecimal('0.01')
      end
    end
  end
end
