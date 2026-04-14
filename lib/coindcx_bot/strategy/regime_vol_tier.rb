# frozen_string_literal: true

require_relative 'signal'

module CoindcxBot
  module Strategy
    # Wraps an inner strategy; gates **new** entries using HMM tier / uncertainty from Engine.
    class RegimeVolTier
      def initialize(strategy_config, inner:)
        @cfg = strategy_config.transform_keys(&:to_sym)
        @inner = inner
      end

      def evaluate(pair:, candles_htf:, candles_exec:, position:, ltp:, regime_hint: nil)
        sig = @inner.evaluate(
          pair: pair,
          candles_htf: candles_htf,
          candles_exec: candles_exec,
          position: position,
          ltp: ltp,
          regime_hint: nil
        )
        return sig if position

        if regime_hint && uncertain?(regime_hint) && entry_action?(sig)
          return hold(pair, 'regime_uncertainty')
        end

        tier = regime_hint&.dig(:tier)
        if tier == :high_vol && block_high_vol? && entry_action?(sig)
          return hold(pair, 'regime_high_vol')
        end

        sig
      end

      private

      def hold(pair, reason)
        Signal.new(action: :hold, pair: pair, side: nil, stop_price: nil, reason: reason, metadata: {})
      end

      def entry_action?(sig)
        %i[open_long open_short].include?(sig.action)
      end

      def uncertain?(hint)
        st = hint[:state]
        return false unless st

        st.uncertainty || (block_on_flicker? && st.flickering)
      end

      def block_on_flicker?
        v = @cfg[:block_on_flicker]
        v == true || v.to_s.downcase == 'true'
      end

      def block_high_vol?
        return true unless @cfg.key?(:block_entries_high_vol)

        v = @cfg[:block_entries_high_vol]
        v == true || v.to_s.downcase == 'true' || v.to_s == '1'
      end
    end
  end
end
