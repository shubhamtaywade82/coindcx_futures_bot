# frozen_string_literal: true

require 'bigdecimal'

RSpec.describe CoindcxBot::Alerts::PriceRuleEvaluator do
  let(:state) { {} }

  it 'emits when crossing above-only threshold upward' do
    rules = [{ id: 'r1', pair: 'B-SOL_USDT', above: BigDecimal('100'), label: 'century' }]
    e1 = described_class.evaluate(rules: rules, pair: 'B-SOL_USDT', ltp: BigDecimal('99'), last_side: state)
    expect(e1).to be_empty
    e2 = described_class.evaluate(rules: rules, pair: 'B-SOL_USDT', ltp: BigDecimal('101'), last_side: state)
    expect(e2.size).to eq(1)
    expect(e2.first[:direction]).to include('at_or_below')
    expect(e2.first[:to_zone]).to eq('above')
    expect(e2.first[:threshold_summary]).to eq('above 100')
  end

  it 'does not emit before first zone is established' do
    rules = [{ pair: 'B-SOL_USDT', below: BigDecimal('50') }]
    s = {}
    described_class.evaluate(rules: rules, pair: 'B-SOL_USDT', ltp: BigDecimal('60'), last_side: s)
    e = described_class.evaluate(rules: rules, pair: 'B-SOL_USDT', ltp: BigDecimal('40'), last_side: s)
    expect(e.size).to eq(1)
  end
end
