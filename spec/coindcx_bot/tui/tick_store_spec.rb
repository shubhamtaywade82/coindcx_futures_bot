# frozen_string_literal: true

RSpec.describe CoindcxBot::Tui::TickStore do
  subject(:store) { described_class.new }

  describe '#update and #snapshot' do
    it 'stores a tick retrievable via snapshot' do
      store.update(symbol: 'SOLUSDT', ltp: '142.50', change_pct: '-1.23')

      ticks = store.snapshot
      tick  = ticks['SOLUSDT']

      expect(tick.symbol).to eq('SOLUSDT')
      expect(tick.ltp).to eq(142.50)
      expect(tick.change_pct).to eq(-1.23)
      expect(tick.updated_at).to be_within(1).of(Time.now)
    end

    it 'overwrites previous tick for the same symbol' do
      store.update(symbol: 'SOLUSDT', ltp: '100.0')
      store.update(symbol: 'SOLUSDT', ltp: '105.0')

      expect(store.snapshot['SOLUSDT'].ltp).to eq(105.0)
    end

    it 'keeps ticks for different symbols independent' do
      store.update(symbol: 'SOLUSDT', ltp: '142.50')
      store.update(symbol: 'ETHUSDT', ltp: '3200.0')

      ticks = store.snapshot
      expect(ticks.keys).to contain_exactly('SOLUSDT', 'ETHUSDT')
    end

    it 'returns a frozen snapshot that does not mutate store' do
      store.update(symbol: 'SOLUSDT', ltp: '100.0')
      snap = store.snapshot

      expect(snap).to be_frozen
      expect { snap['NEW'] = 'x' }.to raise_error(FrozenError)
    end

    it 'handles nil change_pct gracefully when there is no prior tick' do
      store.update(symbol: 'SOLUSDT', ltp: '100.0')

      expect(store.snapshot['SOLUSDT'].change_pct).to be_nil
    end

    it 'reuses prior change_pct when a later update omits it' do
      store.update(symbol: 'SOLUSDT', ltp: '100.0', change_pct: '2.5')
      store.update(symbol: 'SOLUSDT', ltp: '101.0')

      tick = store.snapshot['SOLUSDT']
      expect(tick.ltp).to eq(101.0)
      expect(tick.change_pct).to eq(2.5)
    end

    it 'uses provided updated_at for age display' do
      past = Time.utc(2024, 6, 1, 12, 0, 0)
      store.update(symbol: 'SOLUSDT', ltp: '100.0', updated_at: past)

      expect(store.snapshot['SOLUSDT'].updated_at).to eq(past)
    end
  end

  describe '#stale?' do
    it 'returns true for unknown symbols' do
      expect(store.stale?('UNKNOWN')).to be true
    end

    it 'returns false for a freshly updated symbol' do
      store.update(symbol: 'SOLUSDT', ltp: '100.0')

      expect(store.stale?('SOLUSDT', threshold_seconds: 5)).to be false
    end

    it 'returns true when tick is older than threshold' do
      store.update(symbol: 'SOLUSDT', ltp: '100.0')

      expect(store.stale?('SOLUSDT', threshold_seconds: 0)).to be true
    end
  end

  describe 'thread safety' do
    it 'handles concurrent writes without raising' do
      threads = 10.times.map do |i|
        Thread.new do
          50.times { |j| store.update(symbol: "SYM#{i}", ltp: j.to_s) }
        end
      end

      threads.each(&:join)

      expect(store.snapshot.keys.length).to eq(10)
    end
  end
end
