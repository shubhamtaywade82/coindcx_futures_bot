# frozen_string_literal: true

RSpec.describe CoindcxBot::DisplayLtp do
  describe '.merge_prices_by_pair' do
    it 'prefers TickStore LTP when present' do
      ticks = {
        'B-SOL_USDT' => CoindcxBot::Tui::TickStore::Tick.new(
          symbol: 'B-SOL_USDT',
          ltp: 99.0,
          change_pct: 0.1,
          updated_at: Time.now,
          bid: nil,
          ask: nil,
          mark: nil
        )
      }
      tracker = { 'B-SOL_USDT' => { price: BigDecimal('50'), at: Time.now } }

      m = described_class.merge_prices_by_pair(
        %w[B-SOL_USDT],
        tick_store_snapshot: ticks,
        tracker_tick_hash: tracker
      )

      expect(m['B-SOL_USDT']).to eq(99.0)
    end

    it 'falls back to tracker price when TickStore has no row' do
      m = described_class.merge_prices_by_pair(
        %w[B-ETH_USDT],
        tick_store_snapshot: {},
        tracker_tick_hash: { 'B-ETH_USDT' => { price: BigDecimal('2184.19'), at: Time.now } }
      )

      expect(m['B-ETH_USDT']).to eq(BigDecimal('2184.19'))
    end
  end
end
