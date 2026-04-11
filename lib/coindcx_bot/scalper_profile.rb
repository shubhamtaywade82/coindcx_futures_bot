# frozen_string_literal: true

module CoindcxBot
  # Preset tuning when `runtime.mode: scalper` or `COINDCX_BOT_MODE=scalper`.
  # Values are applied only for keys missing from the user's YAML (see {Config#deep_merge_defaults}).
  module ScalperProfile
    ENV_KEY = 'COINDCX_BOT_MODE'

    OVERLAY = {
      runtime: {
        refresh_candles_seconds: 12,
        stale_tick_seconds: 25,
        stale_recovery_sleep_seconds: 2,
        tui_ltp_poll_seconds: 0.25
      },
      strategy: {
        execution_resolution: '5m',
        higher_timeframe_resolution: '15m',
        trend_strength_min: 0.10,
        pullback_ema_tolerance_pct: 0.003,
        compression_lookback: 6,
        breakout_lookback: 3
      }
    }.freeze
  end
end
