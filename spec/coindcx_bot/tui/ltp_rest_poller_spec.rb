# frozen_string_literal: true

RSpec.describe CoindcxBot::Tui::LtpRestPoller do
  let(:market_data) { instance_double(CoindcxBot::Gateways::MarketDataGateway) }
  let(:tick_store) { CoindcxBot::Tui::TickStore.new }
  let(:render_loop) { instance_double(CoindcxBot::Tui::RenderLoop, request_redraw: nil) }

  describe '#refresh_pair (via send)' do
    it 'writes tick_store when the gateway returns a quote' do
      allow(market_data).to receive(:fetch_instrument_display_quote).with(pair: 'B-SOL_USDT').and_return(
        CoindcxBot::Gateways::Result.ok({ price: BigDecimal('10.5'), change_pct: BigDecimal('0.1') })
      )

      poller = described_class.new(
        market_data: market_data,
        pairs: ['B-SOL_USDT'],
        tick_store: tick_store,
        render_loop: render_loop,
        interval_seconds: 60,
        logger: nil
      )
      poller.send(:refresh_pair, 'B-SOL_USDT')

      snap = tick_store.snapshot['B-SOL_USDT']
      expect(snap.ltp).to eq(10.5)
      expect(snap.change_pct).to eq(0.1)
    end

    it 'skips tick_store when the gateway fails' do
      allow(market_data).to receive(:fetch_instrument_display_quote).and_return(
        CoindcxBot::Gateways::Result.fail(:request, 'nope')
      )

      poller = described_class.new(
        market_data: market_data,
        pairs: ['B-SOL_USDT'],
        tick_store: tick_store,
        render_loop: render_loop,
        interval_seconds: 60,
        logger: nil
      )
      poller.send(:refresh_pair, 'B-SOL_USDT')

      expect(tick_store.snapshot['B-SOL_USDT']).to be_nil
    end
  end
end
