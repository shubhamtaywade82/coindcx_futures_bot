# frozen_string_literal: true

require 'bigdecimal'

RSpec.describe CoindcxBot::Execution::GatewayPaperBroker do
  let(:orders) { instance_double(CoindcxBot::Gateways::OrderGateway) }
  let(:account) { instance_double(CoindcxBot::Gateways::AccountGateway) }
  let(:journal) { instance_double(CoindcxBot::Persistence::Journal) }
  let(:config) { instance_double(CoindcxBot::Config) }
  let(:exposure) { instance_double(CoindcxBot::Risk::ExposureGuard) }

  let(:broker) do
    described_class.new(
      order_gateway: orders,
      account_gateway: account,
      journal: journal,
      config: config,
      exposure_guard: exposure,
      logger: nil,
      tick_base_url: 'http://127.0.0.1:9',
      tick_path: '/exchange/v1/paper/simulation/tick',
      api_key: 'k',
      api_secret: 's'
    )
  end

  describe '#unrealized_pnl' do
    it 'marks journal positions to market like PaperBroker so the TUI header matches the matrix' do
      allow(journal).to receive(:open_positions).and_return(
        [
          { pair: 'B-ETH_USDT', side: 'short', quantity: '0.413634', entry_price: '2188.90' }
        ]
      )
      ltp_map = { 'B-ETH_USDT' => BigDecimal('2186.23') }

      u = broker.unrealized_pnl(ltp_map)
      # (2188.90 - 2186.23) * 0.413634 ≈ 1.1044 USDT short
      expect(u).to be_within(BigDecimal('0.001')).of(BigDecimal('1.10440278'))
    end
  end
end
