# frozen_string_literal: true

RSpec.describe CoindcxBot::Tui::RenderLoop do
  let(:panel) { double('panel') }
  let(:render_loop) { described_class.new(panels: [panel], interval: 0.05) }

  after { render_loop.stop }

  describe '#start and #stop' do
    it 'calls render on each panel repeatedly' do
      call_count = 0
      allow(panel).to receive(:render) { call_count += 1 }

      render_loop.start
      sleep 0.2
      render_loop.stop

      expect(call_count).to be >= 2
    end

    it 'reports running? while active' do
      allow(panel).to receive(:render)

      render_loop.start
      expect(render_loop.running?).to be true

      render_loop.stop
      expect(render_loop.running?).to be false
    end
  end

  describe 'error resilience' do
    it 'continues rendering after a panel raises' do
      call_count = 0
      allow(panel).to receive(:render) do
        call_count += 1
        raise 'boom' if call_count == 1
      end

      render_loop.start
      sleep 0.2
      render_loop.stop

      expect(call_count).to be >= 2
    end
  end
end
