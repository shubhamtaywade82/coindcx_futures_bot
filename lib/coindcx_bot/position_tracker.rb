# frozen_string_literal: true

module CoindcxBot
  class PositionTracker
    def initialize(journal:, stale_tick_seconds: 45)
      @journal = journal
      @stale_seconds = stale_tick_seconds
      @ticks = {}
      @mutex = Mutex.new
    end

    def record_tick(tick)
      @mutex.synchronize { @ticks[tick.pair] = tick }
    end

    def ltp(pair)
      @mutex.synchronize { @ticks[pair]&.price }
    end

    def last_tick_at(pair)
      @mutex.synchronize { @ticks[pair]&.received_at }
    end

    def feed_stale?(pair)
      at = last_tick_at(pair)
      return true unless at

      Time.now - at > @stale_seconds
    end

    def any_feed_stale?(pairs)
      pairs.any? { |p| feed_stale?(p) }
    end

    def open_position_for(pair)
      @journal.open_positions.find { |row| row[:pair] == pair }
    end
  end
end
