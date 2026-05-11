# frozen_string_literal: true

# Minimal scriptable stand-in for `CoindcxBot::Exchanges::Binance::DepthWs`
# used by ResyncManager specs. Real WS plumbing is exercised in shadow runs;
# the orchestration logic is tested by pushing events directly.
class FakeDepthWs
  def initialize
    @on_event = nil
    @connected = false
  end

  attr_reader :connected
  alias connected? connected

  def on_event(&block)
    @on_event = block
    self
  end

  def connect
    @connected = true
    self
  end

  def disconnect
    @connected = false
    self
  end

  def push_event(event)
    @on_event&.call(event)
  end
end
