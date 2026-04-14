# frozen_string_literal: true

module CoindcxBot
  module SmcSetup
    module States
      PENDING_SWEEP = 'pending_sweep'
      SWEEP_SEEN = 'sweep_seen'
      AWAITING_CONFIRMATIONS = 'awaiting_confirmations'
      ARMED_ENTRY = 'armed_entry'
      ACTIVE = 'active'
      COMPLETED = 'completed'
      INVALIDATED = 'invalidated'

      TERMINAL = [COMPLETED, INVALIDATED].freeze

      def self.actionable?(state)
        !TERMINAL.include?(state.to_s)
      end
    end
  end
end
