# frozen_string_literal: true

RSpec.describe CoindcxBot::TradingAi::FeatureEnricher do
  let(:fixed_clock) { -> { Time.utc(2024, 6, 15, 12, 0, 0) } }

  def rising_candles(count)
    count.times.map do |i|
      {
        timestamp: Time.utc(2024, 1, 1) + (i * 3600),
        open: 100.0 + i,
        high: 102.0 + i,
        low: 99.0 + i,
        close: 101.0 + i,
        volume: 500.0 + (i * 50)
      }
    end
  end

  describe '.call' do
    it 'raises when candles are empty' do
      expect do
        described_class.call(candles: [], smc: {}, dtw: {}, clock: fixed_clock)
      end.to raise_error(ArgumentError, 'candles cannot be empty')
    end

    it 'normalizes ohlcv shorthand keys on hash candles' do
      candles = [
        { o: 10, h: 11, l: 9, c: 10.5, v: 100 },
        { o: 10.5, h: 12, l: 10, c: 11.5, v: 120 }
      ]
      out = described_class.call(candles: candles, smc: { htf_bias: 'neutral' }, dtw: {}, clock: fixed_clock)
      expect(out[:price]).to eq(11.5)
      expect(out[:meta][:candle_count]).to eq(2)
    end

    it 'labels volatility regime from ATR percentile' do
      candles = rising_candles(40)
      out = described_class.call(candles: candles, smc: { htf_bias: 'bull' }, dtw: {}, clock: fixed_clock)
      expect(out[:volatility]).to include(:regime, :atr_percentile, :atr_trend)
      expect(%w[low normal high]).to include(out[:volatility][:regime])
    end

    it 'flags a bearish rejection when the upper wick dominates a bearish close' do
      candles = rising_candles(30)
      candles[-1] = {
        timestamp: Time.utc(2024, 1, 2),
        open: 100.0,
        high: 110.0,
        low: 99.0,
        close: 99.5,
        volume: 800.0
      }
      out = described_class.call(candles: candles, smc: {}, dtw: {}, clock: fixed_clock)
      expect(out[:candle][:rejection]).to eq('bearish')
    end

    it 'counts consecutive bullish closes from the last bar backward' do
      base = rising_candles(25)
      4.times do |j|
        i = 25 + j
        base << {
          timestamp: Time.utc(2024, 1, 2) + j,
          open: 100.0 + j * 0.1,
          high: 101.0 + j * 0.2,
          low: 99.5,
          close: 100.5 + j * 0.2,
          volume: 600.0
        }
      end
      out = described_class.call(candles: base, smc: {}, dtw: {}, clock: fixed_clock)
      expect(out[:momentum][:consecutive_bull_candles]).to be >= 4
    end

    it 'sets smc_bull_vs_dtw_distribution when SMC is bull and DTW leans bear' do
      candles = rising_candles(30)
      out = described_class.call(
        candles: candles,
        smc: { htf_bias: 'bull' },
        dtw: { whale_sell: true },
        clock: fixed_clock
      )
      expect(out[:conflicts][:smc_bull_vs_dtw_distribution]).to be(true)
    end

    it 'aggregates statistics from history rows with the same setup class' do
      candles = rising_candles(30)
      history = [
        { setup_class: 'neutral', win: true, rr: 2.0, tp1_hit: true },
        { setup_class: 'neutral', win: false, rr: 1.0, tp1_hit: false }
      ]
      out = described_class.call(
        candles: candles,
        smc: { htf_bias: 'neutral' },
        dtw: {},
        history: history,
        clock: fixed_clock
      )
      expect(out[:statistics][:setup_class]).to eq('neutral')
      expect(out[:statistics][:sample_size]).to eq(2)
      expect(out[:statistics][:win_rate]).to eq(0.5)
    end

    it 'computes trade_quality rr from entry stop and first target' do
      candles = rising_candles(30)
      out = described_class.call(
        candles: candles,
        smc: { htf_bias: 'bull' },
        dtw: {},
        entry: 100.0,
        stop_loss: 98.0,
        targets: [104.0, 106.0],
        clock: fixed_clock
      )
      expect(out[:trade_quality][:rr]).to eq(2.0)
      expect(out[:risk][:stop_loss_distance_pct]).to eq(2.0)
    end

    it 'uses the injected clock for enriched_at' do
      candles = rising_candles(25)
      out = described_class.call(candles: candles, smc: {}, dtw: {}, clock: fixed_clock)
      expect(out[:meta][:enriched_at]).to eq('2024-06-15T12:00:00Z')
    end

    it 'classifies asia session open phase from the last bar local time' do
      candles = rising_candles(29) + [
        { timestamp: Time.utc(2024, 6, 1, 0, 30, 0), open: 1, high: 2, low: 0.5, close: 1.5, volume: 10 }
      ]
      out = described_class.call(
        candles: candles,
        smc: {},
        dtw: {},
        tz_offset_minutes: 0,
        clock: fixed_clock
      )
      expect(out[:session][:current]).to eq('asia')
      expect(out[:session][:phase]).to eq('open')
    end
  end
end
