# frozen_string_literal: true

module CoindcxBot
  module Orderflow
    # Detects absorption: a price level being repeatedly defended while the mid-price barely moves.
    #
    # Without a live trades feed we proxy "volume consumed at level" via cumulative removed-size
    # in successive book diffs.  When mid stays within a tight band AND cumulative removed-size
    # at any level exceeds the threshold, absorption is flagged.
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

      # Called from the WS thread after each book update.
      # Returns a signal Hash or nil.
      def on_book_update(pair:, snap:, diff:)
        return nil unless snap && diff

        mid = compute_mid(snap)
        return nil unless mid

        @mutex.synchronize do
          track_mid(pair, mid)
          track_consumed(pair, diff)
          evaluate(pair, mid)
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

      def track_consumed(pair, diff)
        c = @consumed[pair]
        diff.bid_removed.each { |p, s| c[p] = (c[p] || 0.0) + s }
        diff.ask_removed.each { |p, s| c[p] = (c[p] || 0.0) + s }
        # Prune noise entries to prevent unbounded growth
        c.reject! { |_, v| v < 1.0 } if c.size > 300
      end

      def evaluate(pair, _current_mid)
        mids = @mids[pair]
        return nil if mids.size < (window / 2)

        min_mid = mids.min
        return nil if min_mid.zero?

        range_pct = ((mids.max - min_mid) / min_mid * 100.0).abs
        return nil if range_pct > price_range_pct

        c = @consumed[pair]
        return nil if c.empty?

        price_str, volume = c.max_by { |_, v| v }
        return nil if volume < min_volume

        {
          type:       :absorption,
          pair:       pair,
          price:      price_str,
          volume:     volume.round(2),
          range_pct:  range_pct.round(4)
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
