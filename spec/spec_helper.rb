# frozen_string_literal: true

require 'bundler/setup'
require 'tempfile'
require 'coindcx_bot'

RSpec.configure do |config|
  config.filter_run_when_matching :focus
end

def minimal_bot_config(overrides = {})
  base = {
    pairs: %w[B-SOL_USDT B-ETH_USDT],
    margin_currency_short_name: 'USDT',
    inr_per_usdt: 83,
    capital_inr: 50_000,
    risk: {
      per_trade_inr_min: 250,
      per_trade_inr_max: 500,
      max_daily_loss_inr: 1500,
      max_open_positions: 2,
      max_leverage: 5
    },
    strategy: {
      execution_resolution: '15m',
      higher_timeframe_resolution: '1h',
      ema_fast: 12,
      ema_slow: 26,
      atr_period: 14,
      trend_strength_min: 0.12,
      compression_lookback: 8,
      compression_ratio: 0.65,
      breakout_lookback: 4,
      pullback_ema_tolerance_pct: 0.0025
    },
    execution: { order_defaults: { margin_currency_short_name: 'USDT' } },
    runtime: {
      journal_path: File.join(Dir.tmpdir, "coindcx_bot_journal_#{Process.pid}.sqlite3"),
      candle_lookback: 120,
      refresh_candles_seconds: 60,
      stale_tick_seconds: 45,
      dry_run: true
    }
  }
  deep_merge(base, overrides)
end

def deep_merge(a, b)
  a.merge(b) do |_k, x, y|
    x.is_a?(Hash) && y.is_a?(Hash) ? deep_merge(x, y) : y
  end
end
