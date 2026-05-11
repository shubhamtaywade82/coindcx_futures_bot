# frozen_string_literal: true

require 'logger'

RSpec.describe CoindcxBot::Core::Engine, 'liquidity confluence integration' do
  around do |example|
    prev_key = ENV['COINDCX_API_KEY']
    prev_sec = ENV['COINDCX_API_SECRET']
    ENV['COINDCX_API_KEY'] = 'test_key'
    ENV['COINDCX_API_SECRET'] = 'test_secret'
    CoinDCX.reset_configuration!
    example.run
  ensure
    prev_key.nil? ? ENV.delete('COINDCX_API_KEY') : ENV['COINDCX_API_KEY'] = prev_key
    prev_sec.nil? ? ENV.delete('COINDCX_API_SECRET') : ENV['COINDCX_API_SECRET'] = prev_sec
    CoinDCX.reset_configuration!
  end

  let(:logger) { Logger.new(File::NULL) }

  it 'does not allocate liquidity filter when confluence is disabled' do
    cfg = CoindcxBot::Config.new(
      minimal_bot_config(
        orderflow: {
          enabled: true,
          binance: { enabled: true, symbols: { 'SOLUSDT' => 'B-SOL_USDT' } },
          confluence: { enabled: false }
        }
      )
    )
    eng = described_class.new(config: cfg, logger: logger)
    expect(eng.instance_variable_get(:@liquidity_filter)).to be_nil
  end

  it 'allocates liquidity filter when orderflow, binance shadow, and confluence are enabled' do
    cfg = CoindcxBot::Config.new(
      minimal_bot_config(
        orderflow: {
          enabled: true,
          binance: { enabled: true, symbols: { 'SOLUSDT' => 'B-SOL_USDT' } },
          confluence: { enabled: true }
        }
      )
    )
    eng = described_class.new(config: cfg, logger: logger)
    expect(eng.instance_variable_get(:@liquidity_context_store)).to be_a(CoindcxBot::Orderflow::LiquidityContextStore)
    expect(eng.instance_variable_get(:@liquidity_filter)).to be_a(CoindcxBot::Orderflow::LiquidityConfluenceFilter)
  end

  it 'logs signal_filtered_liquidity when filter adds liquidity metadata' do
    journal = instance_double(CoindcxBot::Persistence::Journal, paused?: false, kill_switch?: false)
    allow(journal).to receive(:log_event)
    cfg = CoindcxBot::Config.new(
      minimal_bot_config(
        orderflow: {
          enabled: true,
          binance: { enabled: true, symbols: { 'SOLUSDT' => 'B-SOL_USDT' } },
          confluence: { enabled: true, max_context_age_ms: 120_000, rules: { wall_in_path_veto: false,
                                                                              sweep_confirms: true } }
        }
      )
    )
    eng = described_class.new(config: cfg, logger: logger)
    eng.instance_variable_set(:@journal, journal)
    ts = (Time.now.to_f * 1000).to_i
    eng.instance_variable_get(:@bus).publish(
      :'liquidity.sweep.detected',
      { pair: 'B-SOL_USDT', source: :binance, side: :bid, levels_swept: 3, notional: BigDecimal('1'), ts: ts }
    )
    before_sig = CoindcxBot::Strategy::Signal.new(
      action: :open_long, pair: 'B-SOL_USDT', side: :long, stop_price: BigDecimal('1'), reason: 'x', metadata: {}
    )
    after_sig = eng.instance_variable_get(:@liquidity_filter).filter(before_sig, entry_price: BigDecimal('100'))
    eng.send(:log_signal_filtered_liquidity_if_needed!, before_sig, after_sig)
    expect(journal).to have_received(:log_event).with(
      'signal_filtered_liquidity',
      hash_including(pair: 'B-SOL_USDT', liquidity: hash_including(sweep_confirm: true))
    )
  end
end
