# frozen_string_literal: true

RSpec.describe CoindcxBot::Alerts::TelegramPolicy do
  it 'permits all types when allow_types is empty' do
    policy = described_class.new(
      CoindcxBot::Config.new(
        minimal_bot_config(
          alerts: { filter_telegram: true, telegram: { default_throttle_seconds: 0 } }
        )
      )
    )
    expect(policy.permit?('anything', { pair: 'B-X' }, Time.at(100))).to be true
  end

  it 'blocks types not in allowlist when allow_types is set' do
    policy = described_class.new(
      CoindcxBot::Config.new(
        minimal_bot_config(
          alerts: {
            filter_telegram: true,
            telegram: { allow_types: %w[analysis_price_cross], default_throttle_seconds: 0 }
          }
        )
      )
    )
    expect(policy.permit?('noise', {}, Time.at(1))).to be false
    expect(policy.permit?('analysis_price_cross', { pair: 'B-SOL_USDT' }, Time.at(1))).to be true
  end

  it 'always permits critical types when allowlisted filter is on' do
    policy = described_class.new(
      CoindcxBot::Config.new(
        minimal_bot_config(
          alerts: {
            filter_telegram: true,
            telegram: { allow_types: %w[analysis_price_cross], default_throttle_seconds: 0 }
          }
        )
      )
    )
    expect(policy.permit?('open_failed', { pair: 'B-SOL_USDT' }, Time.at(1))).to be true
  end

  it 'throttles repeat deliveries by dedupe key' do
    policy = described_class.new(
      CoindcxBot::Config.new(
        minimal_bot_config(
          alerts: { filter_telegram: true, telegram: { default_throttle_seconds: 60 } }
        )
      )
    )
    t0 = Time.at(0)
    expect(policy.permit?('analysis_price_cross', { pair: 'B-P', dedupe_key: 'x' }, t0)).to be true
    expect(policy.permit?('analysis_price_cross', { pair: 'B-P', dedupe_key: 'x' }, Time.at(30))).to be false
    expect(policy.permit?('analysis_price_cross', { pair: 'B-P', dedupe_key: 'x' }, Time.at(61))).to be true
  end

  it 'permits everything when filter_telegram is off regardless of allowlist' do
    policy = described_class.new(CoindcxBot::Config.new(minimal_bot_config))
    expect(policy.permit?('any', {}, Time.at(1))).to be true
  end
end
