# frozen_string_literal: true

RSpec.describe CoindcxBot::Strategy::SupertrendProfit do
  def c(t, o, h, l, cl, v = 1)
    CoindcxBot::Dto::Candle.new(
      time: Time.at(t), open: BigDecimal(o.to_s), high: BigDecimal(h.to_s),
      low: BigDecimal(l.to_s), close: BigDecimal(cl.to_s), volume: BigDecimal(v.to_s)
    )
  end

  let(:cfg) do
    {
      supertrend_atr_period: 3,
      supertrend_multiplier: 2,
      take_profit_pct: 0.10,
      stop_distance_pct_for_sizing: 0.02
    }
  end

  subject(:strategy) { described_class.new(cfg) }

  describe 'take-profit exit' do
    it 'emits close when long is up at least take_profit_pct' do
      position = { id: 7, side: 'long', entry_price: '100', stop_price: '98', quantity: '0.01' }
      sig = strategy.evaluate(
        pair: 'B-X_USDT',
        candles_htf: [],
        candles_exec: [c(0, 1, 2, 1, 1)],
        position: position,
        ltp: BigDecimal('111')
      )
      expect(sig.action).to eq(:close)
      expect(sig.metadata[:position_id]).to eq(7)
      expect(sig.reason).to eq('take_profit_pct')
    end

    it 'emits close when short is down at least take_profit_pct' do
      position = { id: 2, side: 'short', entry_price: '100', stop_price: '102', quantity: '0.01' }
      sig = strategy.evaluate(
        pair: 'B-X_USDT',
        candles_htf: [],
        candles_exec: [c(0, 1, 2, 1, 1)],
        position: position,
        ltp: BigDecimal('89')
      )
      expect(sig.action).to eq(:close)
    end

    it 'holds when below take profit' do
      position = { id: 1, side: 'long', entry_price: '100', stop_price: '98', quantity: '0.01' }
      sig = strategy.evaluate(
        pair: 'B-X_USDT',
        candles_htf: [],
        candles_exec: [c(0, 1, 2, 1, 1)],
        position: position,
        ltp: BigDecimal('105')
      )
      expect(sig.action).to eq(:hold)
    end
  end

  describe 'stop-loss exit' do
    it 'emits close when long price falls to or below stop_price' do
      position = { id: 3, side: 'long', entry_price: '100', stop_price: '95', quantity: '0.01',
                   initial_stop_price: '95' }
      sig = strategy.evaluate(
        pair: 'B-X_USDT',
        candles_htf: [],
        candles_exec: [c(0, 1, 2, 1, 1)],
        position: position,
        ltp: BigDecimal('94.99')
      )
      expect(sig.action).to eq(:close)
      expect(sig.reason).to eq('stop')
      expect(sig.metadata[:position_id]).to eq(3)
    end

    it 'emits close when short price rises to or above stop_price' do
      position = { id: 4, side: 'short', entry_price: '100', stop_price: '105', quantity: '0.01',
                   initial_stop_price: '105' }
      sig = strategy.evaluate(
        pair: 'B-X_USDT',
        candles_htf: [],
        candles_exec: [c(0, 1, 2, 1, 1)],
        position: position,
        ltp: BigDecimal('105.01')
      )
      expect(sig.action).to eq(:close)
      expect(sig.reason).to eq('stop')
    end

    it 'does not emit stop close when price is inside stop distance' do
      position = { id: 5, side: 'long', entry_price: '100', stop_price: '95', quantity: '0.01',
                   initial_stop_price: '95' }
      sig = strategy.evaluate(
        pair: 'B-X_USDT',
        candles_htf: [],
        candles_exec: [c(0, 1, 2, 1, 1)],
        position: position,
        ltp: BigDecimal('97')
      )
      # Not yet at TP (10%), not yet at stop — should hold (or trail if DynamicTrail fires)
      expect(%i[hold trail]).to include(sig.action)
    end
  end

  describe 'Supertrend flip entry' do
    let(:closed) { 20.times.map { |i| c(i, 100, 101, 99, 100, 1000) } }
    let(:exec) { closed + [c(99, 100, 101, 99, 100, 1000)] }

    it 'opens long when indicator flips bearish to bullish on closed bars' do
      trends = Array.new(closed.size, :bearish)
      trends[-1] = :bullish
      allow(CoindcxBot::Strategy::Indicators).to receive(:supertrend_trends).and_return(trends)

      sig = strategy.evaluate(
        pair: 'B-X_USDT',
        candles_htf: [],
        candles_exec: exec,
        position: nil,
        ltp: BigDecimal('100')
      )
      expect(sig.action).to eq(:open_long)
      expect(sig.side).to eq(:long)
      expect(sig.reason).to eq('supertrend_bull_flip')
      expect(sig.stop_price).to eq(BigDecimal('98'))
    end

    it 'opens short when indicator flips bullish to bearish' do
      trends = Array.new(closed.size, :bullish)
      trends[-1] = :bearish
      allow(CoindcxBot::Strategy::Indicators).to receive(:supertrend_trends).and_return(trends)

      sig = strategy.evaluate(
        pair: 'B-X_USDT',
        candles_htf: [],
        candles_exec: exec,
        position: nil,
        ltp: BigDecimal('100')
      )
      expect(sig.action).to eq(:open_short)
      expect(sig.stop_price).to eq(BigDecimal('102'))
    end
  end
end
