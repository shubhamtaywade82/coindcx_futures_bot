# frozen_string_literal: true

require 'spec_helper'

RSpec.describe CoindcxBot::Regime::MlPredictor do
  let(:bundle) do
    CoindcxBot::Regime::MlModelBundle.new(
      schema_version: 1,
      model_type: 'multinomial_logistic',
      feature_order: %w[f0 f1],
      classes: %w[neg pos],
      weights: [[-5.0, 0.0], [5.0, 0.0]],
      biases: [0.0, 0.0],
      tier_by_class: { 'neg' => 'low_vol', 'pos' => 'high_vol' }
    )
  end

  let(:predictor) { described_class.new(bundle) }

  it 'predicts the class with higher logit along f0' do
    out = predictor.predict([2.0, 0.0])
    expect(out[:label]).to eq('pos')
    expect(out[:class_index]).to eq(1)
    expect(out[:max_probability]).to be > 0.5
  end

  it 'raises when vector length mismatches bundle' do
    expect { predictor.predict([1.0]) }.to raise_error(ArgumentError, /vector dim/)
  end
end
