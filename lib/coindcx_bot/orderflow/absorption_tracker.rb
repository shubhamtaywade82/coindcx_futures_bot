# frozen_string_literal: true

module CoindcxBot
  module Orderflow
    # Detects absorption: a price level being repeatedly defended while the mid-price barely moves.
    #
    # We track real trade volume executed at specific price levels. When mid stays within
    # a tight band AND cumulative trade volume at any level exceeds the threshold,
    # absorption is flagged.
    class AbsorptionTracker
      DEFAULT_WINDOW          = 20     # snapshots to retain per pair
      DEFAULT_PRICE_RANGE_PCT = 0.05   # mid must stay within 0.05 % over the window
      DEFAULT_MIN_VOLUME      = 5_000.0

      def initialize(config:)
        @config = config
        @mutex  = Mutex.new
        @mids     = Hash.new { |h, k| h[k] = [] }   # pair => [Float]
        @consumed = Hash.new { |h, k| h[k] = {} }   # pair => { price_str => Float }
      end

      # Called from the WS thread when a new trade arrives.
      def on_trade(trade)
        pair = trade[:pair]
        price = trade[:price].to_s
        size = trade[:size].to_f

        @mutex.synchronize do
          c = @consumed[pair]
          c[price] = (c[price] || 0.0) + size
          # Prune old levels if it gets too large
          c.reject! { |_, v| v < 0.1 } if c.size > 500
        end
      end

      # Called from the WS thread after each book update.
      # Returns a signal Hash or nil.
      def on_book_update(pair:, snap:, diff:, source: :coindcx)
        return nil unless snap && diff

        mid = compute_mid(snap)
        return nil unless mid

        @mutex.synchronize do
          track_mid(pair, mid)
          evaluate(pair, mid, source: source)
        end
      rescue StandardError
        nil
      end

      private

      def compute_mid(snap)
        best_bid = snap[:bids].keys.map(&method(:to_f_safe)).compact.max
        best_ask = snap[:asks].keys.map(&method(:to_f_safe)).compact.min
        return nil unless best_bid && best_ask && best_bid < best_ask

        (best_bid + best_ask) / 2.0
      end

      def track_mid(pair, mid)
        arr = @mids[pair]
        arr << mid
        arr.shift while arr.size > window
      end

      def evaluate(pair, _current_mid, source: :coindcx)
        mids = @mids[pair]
        return nil if mids.size < (window / 2)

        min_mid = mids.min
        return nil if min_mid.zero?

        range_pct = ((mids.max - min_mid) / min_mid * 100.0).abs
        return nil if range_pct > price_range_pct

        c = @consumed[pair]
        return nil if c.empty?

        # Find the level with the most volume in the current "stuck" range
        price_str, volume = c.max_by { |_, v| v }
        return nil if volume < min_volume

        # Once flagged, we clear the volume for that level to avoid double-triggering
        # until more volume is absorbed.
        c[price_str] = 0.0

        {
          type:       :absorption,
          pair:       pair,
          price:      price_str,
          volume:     volume.round(2),
          range_pct:  range_pct.round(4),
          source:     source
        }
      end

      # --- config helpers ---

      def section
        @config.respond_to?(:orderflow_section) ? @config.orderflow_section : {}
      end

      def window
        section.fetch(:absorption_window, DEFAULT_WINDOW).to_i
      end

      def price_range_pct
        Float(section.fetch(:absorption_price_range_pct, DEFAULT_PRICE_RANGE_PCT))
      rescue ArgumentError, TypeError
        DEFAULT_PRICE_RANGE_PCT
      end

      def min_volume
        Float(section.fetch(:absorption_volume_threshold, DEFAULT_MIN_VOLUME))
      rescue ArgumentError, TypeError
        DEFAULT_MIN_VOLUME
      end

      def to_f_safe(s)
        Float(s)
      rescue ArgumentError, TypeError
        nil
      end
    end
  end
end
