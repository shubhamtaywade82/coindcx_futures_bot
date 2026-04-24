# frozen_string_literal: true

module CoindcxBot
  module Regime
    # Per-hidden-state summary after training (vol-sorted for strategy mapping).
    RegimeInfo = Struct.new(
      :state_id,
      :label,
      :expected_return,
      :expected_volatility,
      keyword_init: true
    )

    # Filtered belief at a bar (causal).
    RegimeState = Struct.new(
      :state_id,
      :label,
      :probability,
      :probabilities,
      :timestamp,
      :is_confirmed,
      :consecutive_bars,
      :flickering,
      :uncertainty,
      :vol_rank,
      :vol_rank_total,
      keyword_init: true
    )

    # ML regime head: debounced class + per-bar raw argmax (control layer only — not entry direction).
    MlRegimeState = Struct.new(
      :label,
      :class_index,
      :probability,
      :probabilities,
      :tier,
      :raw_label,
      :raw_class_index,
      :raw_max_probability,
      :candle_index,
      keyword_init: true
    )
  end
end
