# frozen_string_literal: true

module CoindcxBot
  module Exchanges
    module Binance
      # Stateless guards for Binance USDⓈ-M Futures depth-stream sequencing.
      # See: https://developers.binance.com/docs/derivatives/usds-margined-futures/websocket-market-streams/Diff-Book-Depth-Streams
      #
      # Two distinct rules:
      #   1. Initial alignment after REST snapshot id `L`: the first applied event
      #      must satisfy `U <= L+1 <= u` (so it covers the snapshot boundary).
      #   2. Subsequent events: each event's `pu` (previous final update id) must
      #      equal the previously applied event's `u`. Any gap means we lost a
      #      packet and the local book is corrupt → resync required.
      module SequenceValidator
        class Desync < StandardError
        end

        module_function

        # @raise [Desync] when the first event does not span the snapshot id.
        def validate_initial!(first_u:, final_u:, snapshot_id:)
          boundary = snapshot_id + 1
          return if boundary.between?(first_u, final_u)

          raise Desync, "initial misalignment: U=#{first_u} u=#{final_u} snapshot=#{snapshot_id}"
        end

        # @raise [Desync] when the event's `pu` does not match the previous `u`.
        def validate_continuity!(prev_u:, last_applied_u:)
          return if prev_u == last_applied_u

          raise Desync, "continuity gap: pu=#{prev_u} expected=#{last_applied_u}"
        end
      end
    end
  end
end
