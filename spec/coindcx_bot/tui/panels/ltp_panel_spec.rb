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

        expect(rendered).to include('SOLUSDT')
        expect(rendered).to include('ETHUSDT')
        expect(rendered).to include('---')
      end
    end

    context 'with a fresh positive tick' do
      before do
        tick_store.update(symbol: 'SOLUSDT', ltp: '142.5000', change_pct: '1.23')
      end

      it 'renders the LTP in green' do
        panel.render

        expect(output.string).to include("\e[32m")
        expect(output.string).to include('142.5000')
      end

      it 'renders the change percentage' do
        panel.render

        expect(output.string).to include('+1.23%')
      end
    end

    context 'with a negative change tick' do
      before do
        tick_store.update(symbol: 'ETHUSDT', ltp: '3200.0', change_pct: '-2.5')
      end

      it 'renders the LTP in red' do
        panel.render

        expect(output.string).to include("\e[31m")
        expect(output.string).to include('3200.0000')
      end
    end

    context 'with a stale tick' do
      it 'renders STALE marker and dims the LTP' do
        tick_store.update(symbol: 'SOLUSDT', ltp: '100.0')
        sleep 0.01

        allow(Time).to receive(:now).and_return(Time.now + 10)
        panel.render

        expect(output.string).to include('[STALE]')
        expect(output.string).to include("\e[2m")
      end
    end
  end

  describe '#row_count' do
    it 'returns header rows plus symbol count' do
      expect(panel.row_count).to eq(4)
    end
  end
end
