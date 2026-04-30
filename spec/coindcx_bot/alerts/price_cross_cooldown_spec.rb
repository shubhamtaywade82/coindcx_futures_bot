# frozen_string_literal: true

RSpec.describe CoindcxBot::Alerts::PriceCrossCooldown do
  subject(:cd) { described_class.new }

  it 'always permits when cooldown is zero' do
    t = Time.at(100)
    expect(cd.permit_emit?(pair: 'B-P', rule_id: 'r1', cooldown_seconds: 0, now: t)).to be(true)
    expect(cd.permit_emit?(pair: 'B-P', rule_id: 'r1', cooldown_seconds: 0, now: t)).to be(true)
  end

  it 'blocks repeat emits for the same pair and rule within the window' do
    t0 = Time.at(0)
    expect(cd.permit_emit?(pair: 'B-P', rule_id: 'r1', cooldown_seconds: 60, now: t0)).to be(true)
    expect(cd.permit_emit?(pair: 'B-P', rule_id: 'r1', cooldown_seconds: 60, now: Time.at(30))).to be(false)
    expect(cd.permit_emit?(pair: 'B-P', rule_id: 'r1', cooldown_seconds: 60, now: Time.at(60))).to be(true)
  end

  it 'tracks pair and rule independently' do
    t0 = Time.at(0)
    expect(cd.permit_emit?(pair: 'B-P', rule_id: 'r1', cooldown_seconds: 60, now: t0)).to be(true)
    expect(cd.permit_emit?(pair: 'B-P', rule_id: 'r2', cooldown_seconds: 60, now: Time.at(1))).to be(true)
  end
end
