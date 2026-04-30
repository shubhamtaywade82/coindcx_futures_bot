# frozen_string_literal: true

module CoindcxBot
  module Orderflow
    # Stateful per-pair L2 book keyed by price string → Float size.
    # Each call to #update! returns a Diff describing what changed vs the previous snapshot.
    # All reads/writes are mutex-protected so WS and main threads can access concurrently.
    class OrderBookStore
      Diff = Struct.new(
        :bid_added,   # Hash{ price_str => Float } — new levels on bid side
        :bid_removed, # Hash{ price_str => Float } — gone levels on bid side
        :ask_added,
        :ask_removed,
        :timestamp,   # Float — Time.now.to_f at update
        keyword_init: true
      )

      EMPTY_DIFF = Diff.new(
        bid_added: {}, bid_removed: {}, ask_added: {}, ask_removed: {}, timestamp: nil
      ).freeze

      def initialize
        @mutex = Mutex.new
        @bids = {}       # pair_str => Hash{ price_str => Float }
        @asks = {}
        @timestamps = {} # pair_str => Float
      end

      # Apply a full L2 snapshot for +pair+.  Returns a Diff.
      # @param bids [Array<Hash>]  e.g. [{ price: "65000", quantity: "1.2" }, ...]
      # @param asks [Array<Hash>]
      def update!(pair:, bids:, asks:)
        sym = pair.to_s
        now = Time.now.to_f
        new_bids = levels_to_map(bids)
        new_asks = levels_to_map(asks)

        @mutex.synchronize do
          prev_bids = @bids[sym] || {}
          prev_asks = @asks[sym] || {}

          diff = Diff.new(
            bid_added:   added(prev_bids, new_bids),
            bid_removed: removed(prev_bids, new_bids),
            ask_added:   added(prev_asks, new_asks),
            ask_removed: removed(prev_asks, new_asks),
            timestamp:   now
          )

          @bids[sym] = new_bids
          @asks[sym] = new_asks
          @timestamps[sym] = now

          diff
        end
      end

      # Thread-safe snapshot of current bids + asks for +pair+.
      def snapshot_for(pair)
        sym = pair.to_s
        @mutex.synchronize do
          {
            bids: @bids[sym]&.dup || {},
            asks: @asks[sym]&.dup || {},
            timestamp: @timestamps[sym]
          }
        end
      end

      private

      # Normalise WS level array → Hash{ price_str => Float }.
      def levels_to_map(levels)
        Array(levels).each_with_object({}) do |l, h|
          next unless l.is_a?(Hash)

          p = (l[:price] || l['price']).to_s.strip
          q = (l[:quantity] || l['quantity']).to_s.strip
          next if p.empty? || q.empty?

          pf = Float(p)
          qf = Float(q)
          next if qf <= 0

          h[p] = qf
        rescue ArgumentError, TypeError
          next
        end
      end

      def added(prev, curr)
        curr.reject { |k, _| prev.key?(k) }
      end

      def removed(prev, curr)
        prev.reject { |k, _| curr.key?(k) }
      end
    end
  end
end
