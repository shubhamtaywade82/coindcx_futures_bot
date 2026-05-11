# frozen_string_literal: true

RSpec.describe CoindcxBot::MarketData::SourceRouter do
  let(:config) do
    double(
      orderflow_section: {
        binance: {
          symbols: {
            'ETHUSDT' => 'B-ETH_USDT'
          }
        }
      }
    )
  end

  it 'returns :binance when YAML maps the CoinDCX pair' do
    router = described_class.new(config)
    expect(router.intelligence_source_for_pair('B-ETH_USDT')).to eq(:binance)
    expect(router.binance_symbol_for_coindcx_pair('B-ETH_USDT')).to eq('ETHUSDT')
  end

  it 'falls back to built-in SymbolMap for known pairs' do
    router = described_class.new(double(orderflow_section: {}))
    expect(router.intelligence_source_for_pair('B-SOL_USDT')).to eq(:binance)
  end

  it 'falls back to :coindcx when no Binance mapping exists' do
    router = described_class.new(double(orderflow_section: {}))
    expect(router.intelligence_source_for_pair('B-UNKNOWN_USDT')).to eq(:coindcx)
  end
end
