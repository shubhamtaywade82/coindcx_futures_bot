# frozen_string_literal: true

require 'bigdecimal'

RSpec.describe CoindcxBot::Strategy::DynamicTrail::Calculator do
  def bd(x)
    BigDecimal(x.to_s)
  end

  def trending_candles(n:, start_price: 100, step: 0.5, bar_range: 2.0)
    n.times.map do |i|
      base = bd(start_price) + bd(i) * bd(step)
      CoindcxBot::Dto::Candle.new(
        time: Time.at(i * 60),
        open: base,
        high: base + bd(bar_range),
        low: base - bd(bar_range / 2.0),
        close: base + bd(step * 0.8),
        volume: bd(100)
      )
    end
  end

  def flat_candles(n:, base_price: 100, bar_range: 1.0)
    n.times.map do |i|
      b = bd(base_price)
      flip = (i.even? ? 1 : -1)
      CoindcxBot::Dto::Candle.new(
        time: Time.at(i * 60),
        open: b,
        high: b + bd(bar_range),
        low: b - bd(bar_range),
        close: b + bd(flip * 0.1),
        volume: bd(100)
      )
    end
  end

  def input_long(candles, entry:, initial_stop:, current_stop:, ltp:)
    CoindcxBot::Strategy::DynamicTrail::Input.new(
      side: :long,
      candles: candles,
      entry_price: entry,
      initial_stop: initial_stop,
      current_stop: current_stop,
      ltp: ltp
    )
  end

  def input_short(candles, entry:, initial_stop:, current_stop:, ltp:)
    CoindcxBot::Strategy::DynamicTrail::Input.new(
      side: :short,
      candles: candles,
      entry_price: entry,
      initial_stop: initial_stop,
      current_stop: current_stop,
      ltp: ltp
    )
  end

  let(:calc) { described_class.new({}) }

  describe 'profit tiers' do
    it 'uses a wider trail distance at low R than at deep R when both ratchet' do
      candles = trending_candles(n: 24)
      out0 = calc.call(input_long(candles, entry: bd(100), initial_stop: bd(90), current_stop: bd(90), ltp: bd(102)))
      out3 = calc.call(input_long(candles, entry: bd(100), initial_stop: bd(90), current_stop: bd(90), ltp: bd(135)))
      expect(out0.changed).to be true
      expect(out3.changed).to be true
      expect(out0.trail_distance).to be > out3.trail_distance
      expect(out0.tier).to eq(0)
      expect(out3.tier).to eq(3)
    end
  end

  describe 'velocity-sensitive trail width' do
    it 'loosens trail in a strong uptrend vs a flat tape at the same R tier' do
      up = trending_candles(n: 24, step: 0.8, bar_range: 2.5)
      flat = flat_candles(n: 24, base_price: 110, bar_range: 0.5)
      out_up = calc.call(input_long(up, entry: bd(100), initial_stop: bd(90), current_stop: bd(90), ltp: bd(108)))
      out_flat = calc.call(input_long(flat, entry: bd(100), initial_stop: bd(90), current_stop: bd(90), ltp: bd(108)))
      expect(out_up.changed).to be true
      expect(out_flat.changed).to be true
      expect(out_up.trail_distance).to be > out_flat.trail_distance
    end
  end

  describe 'volatility ratio' do
    it 'widens trail when short-window ATR dominates baseline ATR' do
      quiet = 18.times.map do |i|
        b = bd(100) + bd(i) * bd('0.05')
        CoindcxBot::Dto::Candle.new(
          time: Time.at(i * 60),
          open: b, high: b + bd('0.2'), low: b - bd('0.2'), close: b, volume: bd(1)
        )
      end
      spike = 6.times.map do |i|
        b = bd(110) + bd(i)
        CoindcxBot::Dto::Candle.new(
          time: Time.at((18 + i) * 60),
          open: b, high: b + bd(8), low: b - bd(2), close: b + bd(4), volume: bd(1)
        )
      end
      wide_vol = quiet + spike
      narrow = trending_candles(n: 24, step: 0.3, bar_range: 0.4)

      out_wide = calc.call(input_long(wide_vol, entry: bd(100), initial_stop: bd(90), current_stop: bd(90), ltp: bd(125)))
      out_narrow = calc.call(input_long(narrow, entry: bd(100), initial_stop: bd(90), current_stop: bd(90), ltp: bd(125)))
      expect(out_wide.changed).to be true
      expect(out_narrow.changed).to be true
      expect(out_wide.vol_factor).to be > out_narrow.vol_factor
    end
  end

  describe 'ratchet' do
    it 'does not move the long stop down when price fades' do
      candles = trending_candles(n: 24)
      first = calc.call(input_long(candles, entry: bd(100), initial_stop: bd(90), current_stop: bd(90), ltp: bd(120)))
      expect(first.changed).to be true
      stop1 = first.stop_price

      faded = candles.dup
      last = faded.last
      faded[-1] = CoindcxBot::Dto::Candle.new(
        time: last.time,
        open: last.open,
        high: last.high,
        low: last.low - bd(5),
        close: last.close - bd(4),
        volume: last.volume
      )

      second = calc.call(input_long(faded, entry: bd(100), initial_stop: bd(90), current_stop: stop1, ltp: bd(105)))
      expect(second.changed).to be false
      expect(second.stop_price).to eq(stop1)
    end
  end

  describe 'break-even gate' do
    it 'forces the long stop at least entry + ATR * gate once profit exceeds 1R' do
      candles = trending_candles(n: 24)
      atr14 = CoindcxBot::Strategy::Indicators.atr(candles, 14)
      entry = bd(100)
      initial = bd(90)
      risk = entry - initial
      ltp = entry + risk * bd('1.1')
      out = calc.call(input_long(candles, entry: entry, initial_stop: initial, current_stop: initial, ltp: ltp))
      expect(out.changed).to be true
      gate = atr14 * bd('0.10')
      expect(out.stop_price).to be >= entry + gate
    end

    it 'does not apply the gate below 1R profit' do
      candles = trending_candles(n: 24)
      entry = bd(100)
      initial = bd(90)
      ltp = bd(105)
      out = calc.call(input_long(candles, entry: entry, initial_stop: initial, current_stop: initial, ltp: ltp))
      expect(out.changed).to be true
      expect(out.tier).to eq(0)
    end
  end

  describe 'insufficient data' do
    it 'returns atr_unavailable when ATR cannot be computed' do
      few = trending_candles(n: 10)
      out = calc.call(input_long(few, entry: bd(100), initial_stop: bd(90), current_stop: bd(90), ltp: bd(110)))
      expect(out.changed).to be false
      expect(out.reason).to eq('atr_unavailable')
    end
  end

  describe 'short symmetry' do
    it 'ratchets the stop down only and never up' do
      down = 24.times.map do |i|
        base = bd(200) - bd(i) * bd('0.5')
        CoindcxBot::Dto::Candle.new(
          time: Time.at(i * 60),
          open: base,
          high: base + bd(1),
          low: base - bd(2),
          close: base - bd('0.4'),
          volume: bd(100)
        )
      end

      first = calc.call(input_short(down, entry: bd(200), initial_stop: bd(210), current_stop: bd(210), ltp: bd(175)))
      expect(first.changed).to be true
      s1 = first.stop_price
      expect(s1).to be < bd(210)

      second = calc.call(input_short(down, entry: bd(200), initial_stop: bd(210), current_stop: s1, ltp: bd(198)))
      expect(second.stop_price).to be <= s1
    end
  end

  describe 'config overrides' do
    it 'disables velocity sensitivity when trail_velocity_weight is 0' do
      zero_vel = described_class.new({ trail_velocity_weight: 0 })
      candles = trending_candles(n: 24)
      out = zero_vel.call(input_long(candles, entry: bd(100), initial_stop: bd(90), current_stop: bd(90), ltp: bd(115)))
      expect(out.changed).to be true
      expect(out.v_factor).to eq(bd(1))
    end
  end

  describe 'trail distance floor' do
    it 'never narrows trail below ATR14 * floor multiplier' do
      candles = trending_candles(n: 24)
      atr14 = CoindcxBot::Strategy::Indicators.atr(candles, 14)
      floor = atr14 * bd('0.40')
      out = calc.call(input_long(candles, entry: bd(100), initial_stop: bd(90), current_stop: bd(90), ltp: bd(140)))
      expect(out.changed).to be true
      expect(out.trail_distance).to be >= floor
    end
  end

  describe 'zero risk distance' do
    it 'returns no change when entry equals initial stop' do
      candles = trending_candles(n: 24)
      out = calc.call(input_long(candles, entry: bd(100), initial_stop: bd(100), current_stop: bd(100), ltp: bd(110)))
      expect(out.changed).to be false
      expect(out.reason).to eq('zero_risk_distance')
    end
  end
end
