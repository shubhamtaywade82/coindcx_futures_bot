# frozen_string_literal: true

RSpec.describe CoindcxBot::Console::RegimeAiContextLoader do
  let(:fixed_now) { Time.utc(2024, 6, 1, 12, 0, 0) }
  let(:config) do
    CoindcxBot::Config.new(
      minimal_bot_config(
        regime: { ai: { bars_per_pair: 8, max_pairs: 2 } },
        runtime: {
          journal_path: File.join(Dir.tmpdir, "coindcx_console_spec_#{Process.pid}.sqlite3"),
          candle_lookback: 10,
          dry_run: true
        }
      )
    )
  end

  let(:md) { instance_double(CoindcxBot::Gateways::MarketDataGateway) }

  def candle_at(i)
    CoindcxBot::Dto::Candle.new(
      time: Time.utc(2024, 6, 1, 11, i, 0),
      open: BigDecimal((100 + i).to_s),
      high: BigDecimal((101 + i).to_s),
      low: BigDecimal((99 + i).to_s),
      close: BigDecimal((100.5 + i).to_s),
      volume: BigDecimal((1000 + i).to_s)
    )
  end

  describe '.fetch!' do
    it 'returns AiBrain-shaped hashes from gateway candles' do
      candles = (1..12).map { |i| candle_at(i) }
      allow(md).to receive(:list_candlesticks) do |args|
        expect(args[:pair]).to match(/\AB-(SOL|ETH)_USDT\z/)
        expect(args[:resolution]).to eq('15m')
        CoindcxBot::Gateways::Result.ok(candles)
      end

      ctx = described_class.fetch!(
        config: config,
        pairs: %w[B-SOL_USDT B-ETH_USDT],
        positions: [],
        md: md,
        clock: -> { fixed_now }
      )

      expect(ctx[:exec_resolution]).to eq('15m')
      expect(ctx[:htf_resolution]).to eq('1h')
      expect(ctx[:positions]).to eq([])
      expect(ctx[:open_count]).to eq(0)
      expect(ctx[:pairs]).to eq(%w[B-SOL_USDT B-ETH_USDT])
      sol = ctx[:candles_by_pair]['B-SOL_USDT']
      expect(sol.size).to eq(8)
      expect(sol.last).to eq(
        o: BigDecimal('112'),
        h: BigDecimal('113'),
        l: BigDecimal('111'),
        c: BigDecimal('112.5'),
        v: BigDecimal('1012')
      )
    end

    it 'raises Error when every pair fails' do
      allow(md).to receive(:list_candlesticks).and_return(
        CoindcxBot::Gateways::Result.fail(:http, 'boom')
      )

      expect do
        described_class.fetch!(
          config: config,
          pairs: ['B-SOL_USDT'],
          positions: [],
          md: md,
          clock: -> { fixed_now }
        )
      end.to raise_error(described_class::Error, /No candlesticks loaded/)
    end
  end
end
