# frozen_string_literal: true

RSpec.describe CoindcxBot::SmcSetup::Validator do
  def valid_hash
    {
      schema_version: 1,
      setup_id: 'u1',
      pair: 'B-SOL_USDT',
      direction: 'long',
      conditions: {
        sweep_zone: { min: 90, max: 100 },
        entry_zone: { min: 95, max: 99 },
        confirmation_required: []
      },
      execution: { sl: 85.0 }
    }
  end

  it 'accepts a minimal valid payload' do
    expect { described_class.validate!(valid_hash) }.not_to raise_error
  end

  it 'parses TradeSetup via parse_trade_setup' do
    ts = described_class.parse_trade_setup(valid_hash)
    expect(ts).to be_a(CoindcxBot::SmcSetup::TradeSetup)
    expect(ts.setup_id).to eq('u1')
  end

  it 'rejects wrong schema_version' do
    expect do
      described_class.validate!(valid_hash.merge(schema_version: 2))
    end.to raise_error(described_class::ValidationError, /schema_version/)
  end

  it 'rejects missing execution.sl' do
    h = valid_hash.dup
    h[:execution] = { sl: nil }
    expect { described_class.validate!(h) }.to raise_error(described_class::ValidationError, /execution.sl/)
  end

  it 'accepts optional invalidation_level and no_trade_zone' do
    h = valid_hash.merge(
      invalidation_level: 88.5,
      conditions: valid_hash[:conditions].merge(no_trade_zone: { min: 50, max: 52 })
    )
    expect { described_class.validate!(h) }.not_to raise_error
  end

  it 'drops non-numeric invalidation_level from planner noise instead of failing' do
    h = valid_hash.merge(invalidation_level: 'below OB low')
    out = described_class.validate!(h)
    expect(out[:invalidation_level]).to be_nil
    ts = described_class.parse_trade_setup(valid_hash.merge(invalidation_level: 'n/a'))
    expect(ts.invalidation_level).to be_nil
  end

  it 'rejects partial no_trade_zone' do
    h = valid_hash.merge(
      conditions: valid_hash[:conditions].merge(no_trade_zone: { min: 50 })
    )
    expect { described_class.validate!(h) }.to raise_error(described_class::ValidationError, /no_trade_zone/)
  end
end
