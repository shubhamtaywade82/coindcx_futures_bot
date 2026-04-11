# frozen_string_literal: true

require 'bigdecimal'

module CoindcxBot
  module Tui
    # Lock-protected L2 snapshot per pair (WebSocket depth-snapshot → capped levels for TUI).
    class OrderBookStore
      Book = Data.define(:bids, :asks, :updated_at)

      MAX_LEVELS = 10
      def initialize
        @mutex = Mutex.new
        @books = {}
      end

      # @param bids [Array<Hash>] e.g. [{ price: "65000", quantity: "1.2" }, ...]
      # @param asks [Array<Hash>]
      def update(pair:, bids:, asks:)
        sym = pair.to_s
        b = normalize_levels(bids).first(MAX_LEVELS).sort_by { |l| -bd(l[:price]) }
        a = normalize_levels(asks).first(MAX_LEVELS).sort_by { |l| bd(l[:price]) }
        @mutex.synchronize do
          @books[sym] = Book.new(bids: b, asks: a, updated_at: Time.now)
        end
      end

      def snapshot
        @mutex.synchronize { @books.transform_values(&:dup).freeze }
      end

      # Top-down: asks (high → best), then bids (best → lower). `book.asks` is ascending (best = min).
      def display_rows(pair:, max_lines:)
        book = @mutex.synchronize { @books[pair.to_s] }
        h = [max_lines.to_i, 1].max
        return Array.new(h) { :empty } unless book

        n_ask = (h / 2.0).ceil
        n_bid = h - n_ask
        ask_slice = book.asks.last([n_ask, book.asks.size].min).reverse
        bid_slice = book.bids.first([n_bid, book.bids.size].min)

        rows = []
        ask_slice.each { |l| rows << { side: :ask, price: l[:price], quantity: l[:quantity] } }
        bid_slice.each { |l| rows << { side: :bid, price: l[:price], quantity: l[:quantity] } }
        rows.fill(:empty, rows.size...h)
        rows.first(h)
      end

      private

      def normalize_levels(rows)
        Array(rows).filter_map do |r|
          next unless r.is_a?(Hash)

          p = r[:price] || r['price']
          q = r[:quantity] || r['quantity']
          next if p.nil? || q.nil? || p.to_s.strip.empty? || q.to_s.strip.empty?

          { price: p.to_s.strip, quantity: q.to_s.strip }
        end
      end

      def bd(v)
        BigDecimal(v.to_s)
      rescue ArgumentError, TypeError
        BigDecimal('0')
      end
    end
  end
end
