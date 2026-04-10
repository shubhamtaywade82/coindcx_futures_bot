# frozen_string_literal: true

module CoindcxBot
  # Single precedence for "what price do we show / mark to?" — matches TUI execution matrix and paper UNREAL.
  module DisplayLtp
    module_function

    # @param pairs [Array<String>] configured instruments
    # @param tick_store_snapshot [Hash<String, TickStore::Tick>] frozen snapshot from {TickStore#snapshot} (may be empty)
    # @param tracker_tick_hash [Hash<String, { price:, at: }>] engine snapshot `:ticks` from {PositionTracker}
    # @return [Hash<String, Numeric|nil>] per-pair last price for display / uPnL
    def merge_prices_by_pair(pairs, tick_store_snapshot:, tracker_tick_hash:)
      Array(pairs).map(&:to_s).each_with_object({}) do |sym, acc|
        row = tick_store_snapshot[sym]
        ltp = row&.ltp
        ltp ||= tracker_tick_hash[sym]&.[](:price)
        acc[sym] = ltp
      end
    end
  end
end
