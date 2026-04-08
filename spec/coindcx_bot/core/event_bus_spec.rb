# frozen_string_literal: true

RSpec.describe CoindcxBot::Core::EventBus do
  it 'delivers published payloads to subscribers' do
    bus = described_class.new
    seen = []
    bus.subscribe(:tick) { |p| seen << p }
    bus.publish(:tick, :a)
    bus.publish(:tick, :b)
    expect(seen).to eq(%i[a b])
  end
end
