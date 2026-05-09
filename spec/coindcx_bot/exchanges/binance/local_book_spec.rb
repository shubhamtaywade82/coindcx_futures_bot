# frozen_string_literal: true

require 'bigdecimal'

RSpec.describe CoindcxBot::Exchanges::Binance::LocalBook do
  let(:book) { described_class.new }

  def bd(value)
    BigDecimal(value.to_s)
  end

  describe '#replace!' do
    it 'loads the snapshot levels and last_update_id' do
      book.replace!(
        last_update_id: 100,
        bids: [['100.5', '2.0'], ['100.4', '1.0']],
        asks: [['100.6', '1.5']]
      )

      expect(book.last_update_id).to eq(100)
      expect(book.best_bid).to eq([bd('100.5'), bd('2.0')])
      expect(book.best_ask).to eq([bd('100.6'), bd('1.5')])
    end

    it 'drops snapshot levels with zero quantity' do
      book.replace!(
        last_update_id: 100,
        bids: [['100.5', '0']],
        asks: []
      )

      expect(book).to be_empty
    end
  end

  describe '#on_delta' do
    it 'emits remove deltas with was_best when the best level is deleted' do
      seen = []
      book.on_delta { |d| seen << d }
      book.replace!(
        last_update_id: 100,
        bids: [['100.5', '2.0'], ['100.4', '1.0']],
        asks: [['100.6', '1.5']]
      )
      seen.clear
      book.apply_diff!(final_u: 101, bids: [['100.5', '0']], asks: [], event_time: 5_000)

      expect(seen.size).to eq(1)
      expect(seen.first[:action]).to eq(:remove)
      expect(seen.first[:was_best]).to eq(true)
      expect(seen.first[:side]).to eq(:bid)
    end
  end

  describe '#apply_diff!' do
    before do
      book.replace!(
        last_update_id: 100,
        bids: [['100.5', '2.0'], ['100.4', '1.0']],
        asks: [['100.6', '1.5']]
      )
    end

    it 'adds new levels' do
      book.apply_diff!(
        final_u: 101,
        bids: [['100.3', '5.0']],
        asks: []
      )

      expect(book.last_update_id).to eq(101)
      expect(book.top_bids(3)).to include([bd('100.3'), bd('5.0')])
    end

    it 'modifies existing levels' do
      book.apply_diff!(
        final_u: 102,
        bids: [['100.5', '7.5']],
        asks: []
      )

      expect(book.best_bid).to eq([bd('100.5'), bd('7.5')])
    end

    it 'deletes a level when quantity is zero' do
      book.apply_diff!(
        final_u: 103,
        bids: [['100.5', '0']],
        asks: []
      )

      expect(book.best_bid).to eq([bd('100.4'), bd('1.0')])
    end

    it 'updates ask side independently of bids' do
      book.apply_diff!(
        final_u: 104,
        bids: [],
        asks: [['100.6', '0'], ['100.7', '4.0']]
      )

      expect(book.best_ask).to eq([bd('100.7'), bd('4.0')])
    end
  end

  describe '#top_bids / #top_asks' do
    it 'returns bids sorted descending and asks ascending' do
      book.replace!(
        last_update_id: 1,
        bids: [%w[100 1], %w[99 2], %w[101 3]],
        asks: [%w[102 1], %w[103 2], %w[104 3]]
      )

      expect(book.top_bids(2).map(&:first)).to eq([bd('101'), bd('100')])
      expect(book.top_asks(2).map(&:first)).to eq([bd('102'), bd('103')])
    end
  end
end
