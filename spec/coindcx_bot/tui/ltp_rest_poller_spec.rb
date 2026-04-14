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

    it 'passes bid and ask into tick_store when the quote includes them' do
      allow(market_data).to receive(:fetch_instrument_display_quote).with(pair: 'B-SOL_USDT').and_return(
        CoindcxBot::Gateways::Result.ok(
          { price: BigDecimal('10'), change_pct: nil, bid: BigDecimal('9.99'), ask: BigDecimal('10.01') }
        )
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
      expect(snap.bid).to eq(9.99)
      expect(snap.ask).to eq(10.01)
    end

    it 'skips tick_store when price is zero' do
      allow(market_data).to receive(:fetch_instrument_display_quote).with(pair: 'B-SOL_USDT').and_return(
        CoindcxBot::Gateways::Result.ok({ price: BigDecimal('0'), change_pct: nil })
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

    it 'synthesizes bid/ask when quote has price but omits book' do
      allow(market_data).to receive(:fetch_instrument_display_quote).with(pair: 'B-SOL_USDT').and_return(
        CoindcxBot::Gateways::Result.ok({ price: BigDecimal('100'), change_pct: BigDecimal('1'), bid: nil, ask: nil })
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
      expect(snap.ltp).to eq(100.0)
      expect(snap.bid).to be_within(1e-6).of(99.99)
      expect(snap.ask).to be_within(1e-6).of(100.01)
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

  describe '#refresh_all_pairs (via send)' do
    let(:poller) do
      described_class.new(
        market_data: market_data,
        pairs: ['B-SOL_USDT'],
        tick_store: tick_store,
        render_loop: render_loop,
        interval_seconds: 60,
        logger: nil
      )
    end

    it 'enriches bid/ask from instrument REST when batch RT quote has ls/pc only' do
      allow(market_data).to receive(:fetch_futures_rt_quotes).with(pairs: ['B-SOL_USDT']).and_return(
        CoindcxBot::Gateways::Result.ok(
          'B-SOL_USDT' => { price: BigDecimal('100'), change_pct: BigDecimal('1.5'), bid: nil, ask: nil }
        )
      )
      allow(market_data).to receive(:fetch_instrument_display_quote).with(pair: 'B-SOL_USDT').and_return(
        CoindcxBot::Gateways::Result.ok(
          price: BigDecimal('100'),
          change_pct: BigDecimal('99'),
          bid: BigDecimal('99.95'),
          ask: BigDecimal('100.05')
        )
      )

      poller.send(:refresh_all_pairs)

      snap = tick_store.snapshot['B-SOL_USDT']
      expect(snap.ltp).to eq(100.0)
      expect(snap.change_pct).to eq(1.5)
      expect(snap.bid).to eq(99.95)
      expect(snap.ask).to eq(100.05)
    end

    it 'continues after a failed poll cycle instead of stopping the loop' do
      calls = 0
      allow(market_data).to receive(:fetch_futures_rt_quotes) do
        calls += 1
        raise StandardError, 'transient' if calls == 1

        CoindcxBot::Gateways::Result.ok(
          'B-SOL_USDT' => { price: BigDecimal('2'), change_pct: nil, bid: nil, ask: nil }
        )
      end
      allow(market_data).to receive(:fetch_instrument_display_quote).with(pair: 'B-SOL_USDT').and_return(
        CoindcxBot::Gateways::Result.ok(price: BigDecimal('2'), change_pct: nil, bid: nil, ask: nil)
      )
      logger = instance_double(Logger, warn: nil)
      allow(logger).to receive(:warn)

      poller = described_class.new(
        market_data: market_data,
        pairs: ['B-SOL_USDT'],
        tick_store: tick_store,
        render_loop: render_loop,
        interval_seconds: 0.01,
        logger: logger
      )
      allow(poller).to receive(:sleep_remaining)
      allow(poller).to receive(:error_cycle_backoff)

      thread = Thread.new { poller.send(:run_loop) }
      sleep 0.2
      expect(calls).to be >= 2
      poller.stop
      thread.join(2)
      expect(thread).not_to be_alive
    end

    it 'does not call instrument REST when batch quote already includes bid and ask' do
      allow(market_data).to receive(:fetch_futures_rt_quotes).with(pairs: ['B-SOL_USDT']).and_return(
        CoindcxBot::Gateways::Result.ok(
          'B-SOL_USDT' => {
            price: BigDecimal('10'),
            change_pct: nil,
            bid: BigDecimal('9.9'),
            ask: BigDecimal('10.1')
          }
        )
      )
      expect(market_data).not_to receive(:fetch_instrument_display_quote)

      poller.send(:refresh_all_pairs)

      snap = tick_store.snapshot['B-SOL_USDT']
      expect(snap.bid).to eq(9.9)
      expect(snap.ask).to eq(10.1)
    end
  end
end
