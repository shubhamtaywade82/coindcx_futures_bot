# frozen_string_literal: true

module CoindcxBot
  module SmcSetup
    # Default {Engine::Snapshot#smc_setup} when the feature is off (TUI strip shows one compact line).
    module TuiOverlay
      DISABLED = {
        enabled: false,
        planner_enabled: false,
        active_count: 0,
        active_setups: []
      }.freeze
    end
  end
end
