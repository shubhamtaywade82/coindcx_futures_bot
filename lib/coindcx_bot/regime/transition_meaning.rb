# frozen_string_literal: true

module CoindcxBot
  module Regime
    # Maps semantic regime labels to trader-readable meaning, bias, and suggested action.
    # Labels are produced by HmmEngine#build_regime_infos from (expected_return, vol_rank_quartile).
    module TransitionMeaning
      LABELS = %w[TREND_UP TREND_DN RANGE CHOP VOL_BULL VOL_BEAR].freeze

      BIAS = {
        'TREND_UP' => :follow_long,
        'TREND_DN' => :follow_short,
        'RANGE' => :mean_revert,
        'CHOP' => :stand_aside,
        'VOL_BULL' => :reduce_long,
        'VOL_BEAR' => :reduce_short
      }.freeze

      ACTION = {
        'TREND_UP' => 'Look for pullback long entries',
        'TREND_DN' => 'Look for rally short entries',
        'RANGE' => 'Fade edges; no breakout chase',
        'CHOP' => 'Wait; avoid new positions',
        'VOL_BULL' => 'Trim longs; wait for contraction',
        'VOL_BEAR' => 'Trim shorts; wait for contraction'
      }.freeze

      TRANSITION_MEANING = {
        %w[RANGE TREND_UP] => 'Range breakout up — trend initiation',
        %w[RANGE TREND_DN] => 'Range breakdown — trend initiation',
        %w[TREND_UP RANGE] => 'Uptrend exhaustion — consolidation',
        %w[TREND_DN RANGE] => 'Downtrend exhaustion — consolidation',
        %w[TREND_UP CHOP] => 'Uptrend failing — noise rising',
        %w[TREND_DN CHOP] => 'Downtrend failing — noise rising',
        %w[CHOP TREND_UP] => 'Noise resolving to up trend',
        %w[CHOP TREND_DN] => 'Noise resolving to down trend',
        %w[CHOP RANGE] => 'Noise contracting to range',
        %w[RANGE CHOP] => 'Range fracturing into noise',
        %w[TREND_UP VOL_BULL] => 'Uptrend accelerating on volatility spike',
        %w[TREND_DN VOL_BEAR] => 'Downtrend accelerating on volatility spike',
        %w[VOL_BULL TREND_UP] => 'Volatility spike resolving to sustained up trend',
        %w[VOL_BEAR TREND_DN] => 'Volatility spike resolving to sustained down trend',
        %w[VOL_BULL RANGE] => 'Volatility fading — range forming',
        %w[VOL_BEAR RANGE] => 'Volatility fading — range forming',
        %w[TREND_UP TREND_DN] => 'Bullish regime flipped bearish',
        %w[TREND_DN TREND_UP] => 'Bearish regime flipped bullish'
      }.freeze

      def self.describe(from_label, to_label)
        to = to_label.to_s
        {
          meaning: TRANSITION_MEANING[[from_label.to_s, to]] || generic(from_label, to),
          bias: BIAS[to] || :unknown,
          action: ACTION[to] || 'Review manually'
        }
      end

      def self.generic(from, to)
        return "Entering #{to}" if from.to_s.empty?

        "#{from} → #{to}"
      end
    end
  end
end
