# frozen_string_literal: true

module CoindcxBot
  module Regime
    # Serializable regime fields for TUI + Engine::Snapshot. HMM wiring fills `active` and metrics.
    module TuiState
      DISABLED = {
        enabled: false,
        active: false,
        label: '—',
        probability_pct: nil,
        stability_bars: nil,
        flicker_display: '—',
        confirmed: nil,
        vol_rank_display: '—',
        transition_display: '—',
        hmm_display: 'off',
        status: 'OFF',
        hint: 'regime.enabled: false'
      }.freeze

      # Feature on in config; HmmEngine not feeding snapshot yet — explicit copy so the strip does not look "empty".
      STANDBY = DISABLED.merge(
        enabled: true,
        active: false,
        label: 'STANDBY',
        probability_pct: nil,
        stability_bars: nil,
        flicker_display: 'n/a',
        confirmed: nil,
        vol_rank_display: 'n/a',
        transition_display: 'n/a',
        hmm_display: 'awaiting HmmEngine',
        status: 'PIPE:IDLE',
        hint: 'Phase 2: wire Regime::HmmEngine → Engine'
      ).freeze

      def self.disabled
        DISABLED
      end

      def self.build(config)
        return DISABLED unless config.respond_to?(:regime_enabled?) && config.regime_enabled?

        STANDBY
      end
    end
  end
end
