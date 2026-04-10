# frozen_string_literal: true

RSpec.describe CoindcxBot::Config do
  it 'treats runtime.paper as dry_run (paper trading mode)' do
    cfg = described_class.new(
      minimal_bot_config(runtime: { journal_path: '/tmp/x.sqlite3', paper: true, dry_run: false })
    )
    expect(cfg.dry_run?).to be(true)
  end

  it 'rejects per_trade_inr_min greater than max' do
    bad = minimal_bot_config(risk: { per_trade_inr_min: 600, per_trade_inr_max: 500 })
    expect { described_class.new(bad) }.to raise_error(CoindcxBot::Config::ConfigurationError, /per_trade_inr_min/)
  end

  it 'enables paper exchange when dry_run and paper_exchange.enabled are set' do
    cfg = described_class.new(
      minimal_bot_config(
        runtime: { dry_run: true },
        paper_exchange: { enabled: true, api_base_url: 'http://127.0.0.1:9292' }
      )
    )
    expect(cfg.paper_exchange_enabled?).to be(true)
    expect(cfg.paper_exchange_api_base).to eq('http://127.0.0.1:9292')
    expect(cfg.paper_exchange_tick_path).to eq('/exchange/v1/paper/simulation/tick')
  end

  it 'does not enable paper exchange when not in dry_run' do
    cfg = described_class.new(
      minimal_bot_config(
        runtime: { dry_run: false, paper: false },
        paper_exchange: { enabled: true, api_base_url: 'http://127.0.0.1:9292' }
      )
    )
    expect(cfg.paper_exchange_enabled?).to be(false)
  end
end
