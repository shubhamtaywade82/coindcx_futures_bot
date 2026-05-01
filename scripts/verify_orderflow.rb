# frozen_string_literal: true

require_relative '../lib/coindcx_bot'

# Mock config
class MockConfig
  def orderflow_enabled?; true end
  def orderflow_ws_depth; 20 end
  def orderflow_section
    {
      imbalance_depth: 5,
      wall_multiplier: 3.0,
      spoof_threshold: 100.0,
      absorption_volume_threshold: 50.0,
      record_sessions: false
    }
  end
end

bus = CoindcxBot::Core::EventBus.new
engine = CoindcxBot::Orderflow::Engine.new(bus: bus, config: MockConfig.new, logger: Logger.new($stdout))

# Listen for signals
bus.subscribe(:orderflow_imbalance) { |ev| puts "SIGNAL: Imbalance #{ev[:value]} (#{ev[:bias]})" }
bus.subscribe(:orderflow_walls) { |ev| puts "SIGNAL: Walls Bids:#{ev[:bid_walls].size} Asks:#{ev[:ask_walls].size}" }
bus.subscribe(:orderflow_absorption) { |ev| puts "SIGNAL: Absorption at #{ev[:price]} Vol:#{ev[:volume]}" }
bus.subscribe(:orderflow_spoof_activity) { |ev| puts "SIGNAL: Spoof Detected #{ev[:events]}" }

puts "--- Phase 1: Imbalance & Walls ---"
engine.on_book_update(
  pair: 'SOLUSDT',
  bids: [{ price: '100', quantity: '50' }, { price: '99', quantity: '50' }],
  asks: [{ price: '101', quantity: '10' }, { price: '102', quantity: '10' }]
)

puts "\n--- Phase 2: Absorption ---"
# Stuck mid-price around 100.5
10.times do |i|
  engine.on_trade(pair: 'SOLUSDT', price: '101', size: 10.0)
  engine.on_book_update(
    pair: 'SOLUSDT',
    bids: [{ price: '100', quantity: '50' }],
    asks: [{ price: '101', quantity: '10' }]
  )
end

puts "\n--- Phase 3: Spoofing ---"
# Add huge ask
engine.on_book_update(
  pair: 'SOLUSDT',
  bids: [{ price: '100', quantity: '50' }],
  asks: [{ price: '101', quantity: '10' }, { price: '110', quantity: '500' }]
)
# Remove huge ask quickly
engine.on_book_update(
  pair: 'SOLUSDT',
  bids: [{ price: '100', quantity: '50' }],
  asks: [{ price: '101', quantity: '10' }]
)

engine.shutdown
