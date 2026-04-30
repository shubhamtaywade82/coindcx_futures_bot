# frozen_string_literal: true

require 'spec_helper'

RSpec.describe CoindcxBot::Regime::MlModelBundle do
  let(:valid_hash) do
    {
      schema_version: 1,
      model_type: 'multinomial_logistic',
      feature_order: %w[a b],
      classes: %w[x y],
      weights: [[1.0, 0.0], [0.0, 1.0]],
      biases: [0.0, 0.0],
      tier_by_class: { 'x' => 'low_vol', 'y' => 'high_vol' }
    }
  end

  it 'loads a valid hash' do
    b = described_class.new(valid_hash)
    expect(b.feature_dimension).to eq(2)
    expect(b.class_count).to eq(2)
    expect(b.classes).to eq(%w[x y])
  end

  it 'rejects unknown schema_version' do
    expect { described_class.new(valid_hash.merge(schema_version: 99)) }.to raise_error(ArgumentError, /schema_version/)
  end

  it 'rejects invalid tier mapping' do
    bad = valid_hash.merge(tier_by_class: { 'x' => 'low_vol', 'y' => 'nope' })
    expect { described_class.new(bad) }.to raise_error(ArgumentError, /invalid tier/)
  end

  it 'rejects weight row length mismatch' do
    bad = valid_hash.merge(weights: [[1.0], [0.0, 1.0]])
    expect { described_class.new(bad) }.to raise_error(ArgumentError, /weights\[0\]/)
  end
end
