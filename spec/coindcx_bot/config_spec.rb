# frozen_string_literal: true

RSpec.describe CoindcxBot::Config do
  it 'rejects per_trade_inr_min greater than max' do
    bad = minimal_bot_config(risk: { per_trade_inr_min: 600, per_trade_inr_max: 500 })
    expect { described_class.new(bad) }.to raise_error(CoindcxBot::Config::ConfigurationError, /per_trade_inr_min/)
  end
end
