# frozen_string_literal: true

RSpec.describe CoindcxBot::Tui::Panels::LtpPanel do
  let(:tick_store) { CoindcxBot::Tui::TickStore.new }
  let(:output)     { StringIO.new }
  let(:symbols)    { %w[SOLUSDT ETHUSDT] }
  let(:panel) do
    described_class.new(
      tick_store: tick_store,
      symbols: symbols,
      origin_row: 0,
      output: output
    )
  end

  describe '#render' do
    context 'with no ticks' do
      it 'renders placeholders for all symbols' do
        panel.render
        rendered = output.string

        expect(rendered).to include('MARKET WATCH')
        expect(rendered).to include('SOLUSDT')
        expect(rendered).to include('ETHUSDT')
        expect(rendered).to include('—')
      end
    end

    context 'with a fresh positive tick' do
      before do
        tick_store.update(symbol: 'SOLUSDT', ltp: '142.5000', change_pct: '1.23')
      end

      it 'renders the LTP in green' do
        panel.render

        expect(output.string).to include("\e[32m")
        expect(output.string).to include('142.50')
      end

      it 'renders the change percentage' do
        panel.render

        expect(output.string).to include('+1.23%')
      end

      it 'renders LIVE status when age is fresh' do
        panel.render
        expect(output.string).to include('LIVE')
      end
    end

    context 'with a negative change tick' do
      before do
        tick_store.update(symbol: 'ETHUSDT', ltp: '3200.0', change_pct: '-2.5')
      end

      it 'renders the LTP in red' do
        panel.render

        expect(output.string).to include("\e[31m")
        expect(output.string).to include('3200.00')
      end
    end

    context 'with engine: STALE follows ws_feed_stale?, AGE follows tick_store updated_at' do
      let(:base) { Time.utc(2025, 6, 1, 12, 0, 0) }
      let(:engine) { instance_double(CoindcxBot::Core::Engine) }
      let(:panel) do
        described_class.new(
          tick_store: tick_store,
          symbols: %w[B-SOL_USDT],
          origin_row: 0,
          stale_tick_seconds: 45,
          engine: engine,
          output: output
        )
      end

      before do
        tick_store.update(symbol: 'B-SOL_USDT', ltp: '100.0', change_pct: '0.1', updated_at: base + 2)
        allow(engine).to receive(:ws_feed_stale?).with('B-SOL_USDT').and_return(true)
        allow(Time).to receive(:now).and_return(base + 50)
      end

      it 'marks STALE in STATUS when ws_feed_stale? while AGE uses tick_store freshness' do
        panel.render
        expect(output.string).to match(/STALE/)
        expect(output.string).to match(/48\.00s/)
      end
    end

    context 'with a stale tick by age' do
      let(:panel) do
        described_class.new(
          tick_store: tick_store,
          symbols: symbols,
          origin_row: 0,
          stale_tick_seconds: 30,
          output: output
        )
      end

      it 'renders STALE status and dims the LTP when quote age exceeds 1s' do
        base = Time.utc(2025, 6, 1, 12, 0, 0)
        tick_store.update(symbol: 'SOLUSDT', ltp: '100.0', updated_at: base)
        allow(Time).to receive(:now).and_return(base + 40)

        panel.render

        expect(output.string).to match(/STALE/)
        expect(output.string).to include("\e[2m")
      end
    end
  end

  describe '#row_count' do
    it 'returns title, header, rule, and symbol rows' do
      expect(panel.row_count).to eq(5)
    end
  end
end
