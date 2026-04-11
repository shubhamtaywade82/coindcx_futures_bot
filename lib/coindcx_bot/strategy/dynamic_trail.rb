# frozen_string_literal: true

require 'bigdecimal'

module CoindcxBot
  module Strategy
    # Institutional-grade dynamic trailing stop calculator.
    #
    # Trail distance = ATR(14) × tier_mult × velocity_factor × vol_factor
    #
    # Tiers (R-multiples):
    #   0–1R  → 2.00×  wide — give room to breathe
    #   1–2R  → 1.50×  moderate — start protecting gains
    #   2–3R  → 1.00×  tight — lock in profits
    #   3R+   → 0.65×  harvesting — aggressively trailing
    #
    # Velocity factor: loosens trail when price is trending hard, tightens when stalling.
    # Vol factor: widens trail when volatility expands (avoid stop-hunts), tightens on contraction.
    # Break-even gate: once profit ≥ 1R, stop is always > entry + small ATR buffer.
    # Ratchet: stop never moves backward.
    module DynamicTrail
      # Value object for Calculator inputs.
      Input = Struct.new(
        :side,         # :long | :short
        :candles,      # Array<Dto::Candle> — exec-timeframe, ideally >= 20 bars
        :entry_price,  # BigDecimal
        :initial_stop, # BigDecimal — stop placed at entry (used for R-distance)
        :current_stop, # BigDecimal — live stop (ratchet baseline)
        :ltp,          # BigDecimal — last traded price
        keyword_init: true
      )

      # Value object for Calculator outputs — carries diagnostic metadata for logging/TUI.
      Output = Struct.new(
        :stop_price,     # BigDecimal — new ratcheted stop
        :changed,        # Boolean
        :tier,           # Integer 0..3 (nil when no change)
        :v_factor,       # BigDecimal (nil when no change)
        :vol_factor,     # BigDecimal (nil when no change)
        :trail_distance, # BigDecimal (nil when no change)
        :reason,         # String
        keyword_init: true
      )

      class Calculator
        # Tier multipliers indexed by tier (0–3).
        TIER_MULTIPLIERS = [
          BigDecimal('2.0'),  # Tier 0: 0–1R  — wide
          BigDecimal('1.5'),  # Tier 1: 1–2R  — moderate
          BigDecimal('1.0'),  # Tier 2: 2–3R  — tight
          BigDecimal('0.65')  # Tier 3: 3R+   — harvesting
        ].freeze

        ATR_BASE_PERIOD     = 14
        ATR_FAST_PERIOD     = 5
        VELOCITY_LOOKBACK   = 3
        VELOCITY_WEIGHT     = BigDecimal('0.25')
        V_FACTOR_MIN        = BigDecimal('0.70')
        V_FACTOR_MAX        = BigDecimal('1.40')
        VOL_RATIO_MIN       = BigDecimal('0.60')
        VOL_RATIO_MAX       = BigDecimal('1.80')
        TRAIL_FLOOR_MULT    = BigDecimal('0.40')
        BREAKEVEN_GATE_MULT = BigDecimal('0.10')
        SWING_LOOKBACK      = 5

        # config: Hash with symbol or string keys — all keys optional; constants are defaults.
        # Config keys (all under strategy: in bot.yml):
        #   trail_atr_period, trail_atr_fast_period, trail_velocity_lookback,
        #   trail_velocity_weight, trail_swing_lookback, trail_floor_mult,
        #   trail_breakeven_gate_mult
        def initialize(config = {})
          @cfg = (config || {}).transform_keys(&:to_sym)
        end

        # Main entry point. Returns Output; never raises.
        def call(input)
          candles      = input.candles
          side         = input.side.to_sym
          entry        = bd(input.entry_price)
          initial_stop = bd(input.initial_stop)
          cur_stop     = bd(input.current_stop)
          ltp          = bd(input.ltp)

          atr14 = Indicators.atr(candles, cfg_i(:trail_atr_period, ATR_BASE_PERIOD))
          return no_change(cur_stop, 'atr_unavailable') if atr14.nil? || atr14.zero?

          fast_period = cfg_i(:trail_atr_fast_period, ATR_FAST_PERIOD)
          atr5 = Indicators.atr(candles, fast_period) || atr14

          risk = (entry - initial_stop).abs
          return no_change(cur_stop, 'zero_risk_distance') if risk.zero?

          profit = side == :long ? ltp - entry : entry - ltp
          tier, tier_mult = profit_tier(profit, risk)
          vf   = velocity_factor(candles, side, atr14)
          volf = vol_factor(atr5, atr14)
          dist = trail_distance(atr14, tier_mult, vf, volf)

          close_price = candles.last.close
          candidate =
            if side == :long
              candidate_long(candles, close_price, dist)
            else
              candidate_short(candles, close_price, dist)
            end

          # Break-even gate: once at least 1R in profit, stop must be above entry
          candidate = breakeven_gate(side, entry, atr14, candidate) if profit >= risk

          # Ratchet — never move stop backward
          new_stop =
            if side == :long
              [candidate, cur_stop].max
            else
              [candidate, cur_stop].min
            end

          changed = new_stop != cur_stop
          Output.new(
            stop_price:     new_stop,
            changed:        changed,
            tier:           changed ? tier : nil,
            v_factor:       changed ? vf : nil,
            vol_factor:     changed ? volf : nil,
            trail_distance: changed ? dist : nil,
            reason:         changed ? "dynamic_trail_tier#{tier}" : 'no_improvement'
          )
        end

        private

        # Returns [tier_index, multiplier] based on profit in R-multiples.
        def profit_tier(profit, risk_distance)
          r = profit.positive? ? profit / risk_distance : BigDecimal('0')
          if r >= BigDecimal('3')
            [3, TIER_MULTIPLIERS[3]]
          elsif r >= BigDecimal('2')
            [2, TIER_MULTIPLIERS[2]]
          elsif r >= BigDecimal('1')
            [1, TIER_MULTIPLIERS[1]]
          else
            [0, TIER_MULTIPLIERS[0]]
          end
        end

        # Price momentum over last N bars normalized by ATR.
        # High positive momentum (trending hard) → factor > 1.0 → loosen trail.
        # Stalling/fading momentum → factor < 1.0 → tighten trail.
        def velocity_factor(candles, side, atr14)
          lookback = cfg_i(:trail_velocity_lookback, VELOCITY_LOOKBACK)
          return BigDecimal('1') if candles.size < lookback + 1

          close_now  = candles.last.close
          close_past = candles[-(lookback + 1)].close
          raw_vel    = (close_now - close_past) / atr14

          # For longs: upward velocity is favourable; for shorts: downward velocity is favourable
          velocity = side == :long ? raw_vel : -raw_vel

          weight = cfg_bd(:trail_velocity_weight, VELOCITY_WEIGHT)
          factor = BigDecimal('1') + velocity * weight
          clamp(factor, V_FACTOR_MIN, V_FACTOR_MAX)
        end

        # Short-window ATR vs baseline ATR.
        # Expanding volatility → wider trail (avoid stop-hunts during breakouts).
        # Contracting volatility → tighter trail (momentum fading, harvest gains).
        def vol_factor(atr5, atr14)
          ratio = atr5 / atr14
          clamp(ratio, VOL_RATIO_MIN, VOL_RATIO_MAX)
        end

        # Combined trail distance, floored at TRAIL_FLOOR_MULT × ATR to prevent stop-hunt width.
        def trail_distance(atr14, tier_mult, vf, volf)
          raw   = atr14 * tier_mult * vf * volf
          floor = atr14 * cfg_bd(:trail_floor_mult, TRAIL_FLOOR_MULT)
          [raw, floor].max
        end

        # Candidate stop for long: max of chandelier and recent swing low.
        def candidate_long(candles, close_price, distance)
          lookback = cfg_i(:trail_swing_lookback, SWING_LOOKBACK)
          swing    = candles.last(lookback).map(&:low).min
          chandelier = close_price - distance
          [swing, chandelier].max
        end

        # Candidate stop for short: min of chandelier and recent swing high.
        def candidate_short(candles, close_price, distance)
          lookback = cfg_i(:trail_swing_lookback, SWING_LOOKBACK)
          swing    = candles.last(lookback).map(&:high).max
          chandelier = close_price + distance
          [swing, chandelier].min
        end

        # Once in ≥ 1R profit, ensure stop is never below entry + ATR × gate_mult (long),
        # or above entry - ATR × gate_mult (short). Prevents closing at near-breakeven after
        # a strong move.
        def breakeven_gate(side, entry, atr14, candidate)
          gate_mult = cfg_bd(:trail_breakeven_gate_mult, BREAKEVEN_GATE_MULT)
          gate_dist = atr14 * gate_mult
          if side == :long
            [candidate, entry + gate_dist].max
          else
            [candidate, entry - gate_dist].min
          end
        end

        def clamp(val, lo, hi)
          [[val, lo].max, hi].min
        end

        def no_change(current_stop, reason)
          Output.new(
            stop_price:     current_stop,
            changed:        false,
            tier:           nil,
            v_factor:       nil,
            vol_factor:     nil,
            trail_distance: nil,
            reason:         reason
          )
        end

        def bd(val)
          BigDecimal(val.to_s)
        end

        def cfg_i(key, default)
          @cfg.fetch(key, default).to_i
        end

        def cfg_bd(key, default)
          BigDecimal(@cfg.fetch(key, default).to_s)
        end
      end
    end
  end
end
