# frozen_string_literal: true

RSpec.describe CoindcxBot::Tui::OrderBookStore do
  subject(:store) { described_class.new }

  describe '#update and #display_rows' do
    it 'stores bids and asks and renders high-to-low ask stack then bids' do
      store.update(
        pair: 'B-BTC_USDT',
        bids: [{ price: '100', quantity: '1' }, { price: '99', quantity: '2' }],
        asks: [{ price: '101', quantity: '3' }, { price: '102', quantity: '4' }]
      )

      rows = store.display_rows(pair: 'B-BTC_USDT', max_lines: 4)
      expect(rows.size).to eq(4)
      expect(rows[0]).to include(side: :ask, price: '102', quantity: '4')
      expect(rows[1]).to include(side: :ask, price: '101', quantity: '3')
      expect(rows[2]).to include(side: :bid, price: '100', quantity: '1')
      expect(rows[3]).to include(side: :bid, price: '99', quantity: '2')
    end

    it 'returns empty rows when pair is unknown' do
      rows = store.display_rows(pair: 'B-ETH_USDT', max_lines: 3)
      expect(rows).to eq(%i[empty empty empty])
    end

    it 'drops depth whose mid is wildly off LTP (Socket.IO cross-pair bleed)' do
      store.update(
        pair: 'B-SOL_USDT',
        bids: [{ price: '2230', quantity: '1' }],
        asks: [{ price: '2232', quantity: '1' }],
        ltp_hint: 84.0
      )
      expect(store.display_rows(pair: 'B-SOL_USDT', max_lines: 3)).to eq(%i[empty empty empty])
    end

    it 'stores depth when mid is consistent with LTP hint' do
      store.update(
        pair: 'B-SOL_USDT',
        bids: [{ price: '83.9', quantity: '1' }],
        asks: [{ price: '84.1', quantity: '1' }],
        ltp_hint: 84.0
      )
      rows = store.display_rows(pair: 'B-SOL_USDT', max_lines: 2)
      expect(rows[0]).to include(side: :ask, price: '84.1')
    end
  end
end
