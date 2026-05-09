# frozen_string_literal: true

RSpec.describe CoindcxBot::TradingAi::TuiAnalysisEventBus do
  subject(:bus) { described_class.new(max_size: 4) }

  describe '#record' do
    it 'appends events with type, payload, at' do
      bus.record(:bos, { pair: 'B-SOL_USDT', side: 'bull' })
      events = bus.peek
      expect(events.size).to eq(1)
      expect(events.first[:type]).to eq(:bos)
      expect(events.first[:payload]).to eq(pair: 'B-SOL_USDT', side: 'bull')
      expect(events.first[:at]).to be_a(Time)
    end

    it 'coerces type to symbol' do
      bus.record('regime_flip')
      expect(bus.peek.first[:type]).to eq(:regime_flip)
    end

    it 'coerces non-hash payloads into empty hash' do
      bus.record(:bos, nil)
      expect(bus.peek.first[:payload]).to eq({})
    end

    it 'drops oldest events when capacity exceeded' do
      6.times { |i| bus.record(:bos, { idx: i }) }
      events = bus.peek
      expect(events.size).to eq(4)
      expect(events.first[:payload]).to eq(idx: 2)
      expect(events.last[:payload]).to eq(idx: 5)
    end
  end

  describe '#pending? / #size' do
    it 'reflects bus contents' do
      expect(bus.pending?).to be(false)
      expect(bus.size).to eq(0)
      bus.record(:bos)
      expect(bus.pending?).to be(true)
      expect(bus.size).to eq(1)
    end
  end

  describe '#drain' do
    it 'returns queued events and clears the bus' do
      bus.record(:bos)
      bus.record(:choch)
      drained = bus.drain
      expect(drained.map { |e| e[:type] }).to eq(%i[bos choch])
      expect(bus.pending?).to be(false)
      expect(bus.drain).to eq([])
    end
  end

  describe '#peek' do
    it 'does not clear the bus' do
      bus.record(:bos)
      bus.peek
      expect(bus.pending?).to be(true)
    end
  end

  describe 'thread safety' do
    it 'survives concurrent writers without dropping below max_size' do
      big_bus = described_class.new(max_size: 1000)
      threads = Array.new(8) do |t|
        Thread.new do
          50.times { |i| big_bus.record(:bos, { t: t, i: i }) }
        end
      end
      threads.each(&:join)
      expect(big_bus.size).to eq(400)
    end
  end
end
