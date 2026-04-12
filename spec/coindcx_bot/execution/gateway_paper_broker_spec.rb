# frozen_string_literal: true

require 'bigdecimal'
require 'json'
require 'faraday'

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

  describe '#close_position' do
    it 'unwraps data.positions and matches B- pair to instrument without B- prefix' do
      allow(account).to receive(:list_positions).and_return(
        CoindcxBot::Gateways::Result.ok(
          'data' => {
            'positions' => [
              {
                'id' => '7',
                'instrument' => 'SOL_USDT',
                'side' => 'long',
                'quantity' => '0.1'
              }
            ]
          }
        )
      )
      allow(account).to receive(:exit_position).and_return(
        CoindcxBot::Gateways::Result.ok('realized_pnl_usdt' => '1.5', 'fill_price' => '84')
      )

      r = broker.close_position(
        pair: 'B-SOL_USDT',
        side: 'long',
        quantity: BigDecimal('0.1'),
        ltp: BigDecimal('84')
      )

      expect(r[:ok]).to be true
      expect(r[:realized_pnl_usdt]).to eq(BigDecimal('1.5'))
      expect(account).to have_received(:exit_position).with(hash_including(id: '7'))
    end

    it 'matches hyphenated instrument codes to bot pair spelling' do
      allow(account).to receive(:list_positions).and_return(
        CoindcxBot::Gateways::Result.ok(
          'positions' => [
            {
              'id' => '9',
              'pair' => 'SOL-USDT',
              'side' => 'short',
              'quantity' => '0.2'
            }
          ]
        )
      )
      allow(account).to receive(:exit_position).and_return(
        CoindcxBot::Gateways::Result.ok('realized_pnl_usdt' => '0', 'fill_price' => '80')
      )

      r = broker.close_position(
        pair: 'B-SOL_USDT',
        side: 'short',
        quantity: BigDecimal('0.2'),
        ltp: BigDecimal('80')
      )

      expect(r[:ok]).to be true
      expect(account).to have_received(:exit_position).with(hash_including(id: '9'))
    end
  end

  describe '#process_tick' do
    let(:stubs) { Faraday::Adapter::Test::Stubs.new }
    let(:conn) do
      Faraday.new(url: 'http://paper.test') do |f|
        f.adapter :test, stubs
      end
    end

    let(:tick_broker) do
      described_class.new(
        order_gateway: orders,
        account_gateway: account,
        journal: journal,
        config: config,
        exposure_guard: exposure,
        logger: nil,
        tick_base_url: 'http://paper.test',
        tick_path: '/exchange/v1/paper/simulation/tick',
        api_key: 'k',
        api_secret: 's',
        faraday_connection: conn
      )
    end

    before do
      stubs.post('/exchange/v1/paper/simulation/tick') do |_env|
        [
          200,
          { 'Content-Type' => 'application/json' },
          JSON.generate(
            'status' => 'ok',
            'position_exits' => [
              {
                'pair' => 'B-SOL_USDT',
                'realized_pnl_usdt' => '-1.25',
                'fill_price' => '94.5',
                'position_id' => 9,
                'trigger' => 'stop_loss'
              }
            ]
          )
        ]
      end
    end

    it 'returns kind :exit rows for the engine from position_exits JSON' do
      rows = tick_broker.process_tick(pair: 'B-SOL_USDT', ltp: BigDecimal('90'), high: BigDecimal('91'), low: BigDecimal('89'))
      expect(rows.size).to eq(1)
      r = rows.first
      expect(r[:kind]).to eq(:exit)
      expect(r[:pair]).to eq('B-SOL_USDT')
      expect(r[:realized_pnl_usdt]).to eq(BigDecimal('-1.25'))
      expect(r[:fill_price]).to eq(BigDecimal('94.5'))
      expect(r[:position_id]).to eq(9)
      expect(r[:trigger]).to eq(:stop_loss)
    end
  end
end
