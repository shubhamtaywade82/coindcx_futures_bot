# frozen_string_literal: true

module CoindcxBot
  module Regime
    # Persistence filter sitting on top of HMM argmax output. Requires +confirmations+ consecutive
    # observations of the same state before marking it stable. Unstable ticks leave +stable_state+
    # unchanged (returns the last stable snapshot, or nil if none yet).
    class StateMachine
      def initialize(confirmations: 2)
        @confirmations = [confirmations.to_i, 1].max
        @buffer = []
        @stable = nil
      end

      # @param state_id [Integer, nil] latest argmax state for a pair
      # @param label [String, nil] semantic label for that state
      # @param posterior [Float, nil] 0..1 posterior probability for the current state
      # @return [Hash, nil] { state_id:, label:, posterior: } when stable, else last stable snapshot
      def update(state_id:, label:, posterior:)
        return @stable if state_id.nil?

        @buffer << state_id
        @buffer.shift while @buffer.size > @confirmations

        if @buffer.size >= @confirmations && @buffer.uniq.size == 1
          @stable = { state_id: state_id, label: label.to_s, posterior: posterior.to_f }
        end
        @stable
      end

      def stable_state
        @stable
      end

      def reset!
        @buffer.clear
        @stable = nil
      end
    end
  end
end
