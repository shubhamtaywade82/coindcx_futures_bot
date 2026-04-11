# frozen_string_literal: true

RSpec.describe CoindcxBot::Tui::TermWidth do
  it 'uses the smaller of TTY::Screen.width and IO.console columns when both exist' do
    allow(TTY::Screen).to receive(:width).and_return(200)
    cons = instance_double(IO, winsize: [24, 118])
    allow(IO).to receive(:console).and_return(cons)
    expect(described_class.columns).to eq(118)
  end

  it 'falls back to TTY width when console is unavailable' do
    allow(TTY::Screen).to receive(:width).and_return(132)
    allow(IO).to receive(:console).and_return(nil)
    expect(described_class.columns).to eq(132)
  end
end
