# frozen_string_literal: true

module CoindcxBot
  module SmcConfluence
    class BarResult
      attr_reader :bar_index,
                  :bos_bull, :bos_bear, :choch_bull, :choch_bear, :structure_bias,
                  :in_bull_ob, :in_bear_ob, :bull_ob_valid, :bear_ob_valid,
                  :bull_ob_hi, :bull_ob_lo, :bear_ob_hi, :bear_ob_lo,
                  :recent_bull_sweep, :recent_bear_sweep,
                  :liq_sweep_bull, :liq_sweep_bear,
                  :ms_trend,
                  :tl_bear_break, :tl_bull_break, :tl_bear_retest, :tl_bull_retest,
                  :sess_level_bull, :sess_level_bear,
                  :vp_bull_conf, :vp_bear_conf, :near_poc, :near_vah, :near_val,
                  :long_score, :short_score, :long_signal, :short_signal,
                  :pdh_sweep, :pdl_sweep,
                  :pdh, :pdl, :poc, :vah, :val_line, :atr14,
                  :fvg_bull_align, :fvg_bear_align, :in_discount, :in_premium,
                  :displacement_present, :displacement_strength,
                  :displacement_range_multiple, :displacement_volume_support,
                  :inducement_present, :inducement_type, :inducement_price, :inducement_swept,
                  :mitigation_reaction_strength

      def initialize(**attrs)
        @bar_index = attrs[:bar_index]
        @bos_bull = attrs[:bos_bull]
        @bos_bear = attrs[:bos_bear]
        @choch_bull = attrs[:choch_bull]
        @choch_bear = attrs[:choch_bear]
        @structure_bias = attrs[:structure_bias]
        @in_bull_ob = attrs[:in_bull_ob]
        @in_bear_ob = attrs[:in_bear_ob]
        @bull_ob_valid = attrs[:bull_ob_valid]
        @bear_ob_valid = attrs[:bear_ob_valid]
        @bull_ob_hi = attrs[:bull_ob_hi]
        @bull_ob_lo = attrs[:bull_ob_lo]
        @bear_ob_hi = attrs[:bear_ob_hi]
        @bear_ob_lo = attrs[:bear_ob_lo]
        @recent_bull_sweep = attrs[:recent_bull_sweep]
        @recent_bear_sweep = attrs[:recent_bear_sweep]
        @liq_sweep_bull = attrs[:liq_sweep_bull]
        @liq_sweep_bear = attrs[:liq_sweep_bear]
        @ms_trend = attrs[:ms_trend]
        @tl_bear_break = attrs[:tl_bear_break]
        @tl_bull_break = attrs[:tl_bull_break]
        @tl_bear_retest = attrs[:tl_bear_retest]
        @tl_bull_retest = attrs[:tl_bull_retest]
        @sess_level_bull = attrs[:sess_level_bull]
        @sess_level_bear = attrs[:sess_level_bear]
        @vp_bull_conf = attrs[:vp_bull_conf]
        @vp_bear_conf = attrs[:vp_bear_conf]
        @near_poc = attrs[:near_poc]
        @near_vah = attrs[:near_vah]
        @near_val = attrs[:near_val]
        @long_score = attrs[:long_score]
        @short_score = attrs[:short_score]
        @long_signal = attrs[:long_signal]
        @short_signal = attrs[:short_signal]
        @pdh_sweep = attrs[:pdh_sweep]
        @pdl_sweep = attrs[:pdl_sweep]
        @pdh = attrs[:pdh]
        @pdl = attrs[:pdl]
        @poc = attrs[:poc]
        @vah = attrs[:vah]
        @val_line = attrs[:val_line]
        @atr14 = attrs[:atr14]
        @fvg_bull_align = attrs.fetch(:fvg_bull_align, false)
        @fvg_bear_align = attrs.fetch(:fvg_bear_align, false)
        @in_discount = attrs.fetch(:in_discount, false)
        @in_premium = attrs.fetch(:in_premium, false)
        @displacement_present = attrs.fetch(:displacement_present, false)
        @displacement_strength = attrs.fetch(:displacement_strength, 'none')
        @displacement_range_multiple = attrs.fetch(:displacement_range_multiple, 0.0)
        @displacement_volume_support = attrs.fetch(:displacement_volume_support, false)
        @inducement_present = attrs.fetch(:inducement_present, false)
        @inducement_type = attrs.fetch(:inducement_type, 'none')
        @inducement_price = attrs.fetch(:inducement_price, nil)
        @inducement_swept = attrs.fetch(:inducement_swept, false)
        @mitigation_reaction_strength = attrs.fetch(:mitigation_reaction_strength, 'none')
      end

      def serialize
        {
          'bar_index' => bar_index,
          'bos_bull' => bos_bull,
          'bos_bear' => bos_bear,
          'choch_bull' => choch_bull,
          'choch_bear' => choch_bear,
          'structure_bias' => structure_bias,
          'in_bull_ob' => in_bull_ob,
          'in_bear_ob' => in_bear_ob,
          'bull_ob_valid' => bull_ob_valid,
          'bear_ob_valid' => bear_ob_valid,
          'bull_ob_hi' => bull_ob_hi,
          'bull_ob_lo' => bull_ob_lo,
          'bear_ob_hi' => bear_ob_hi,
          'bear_ob_lo' => bear_ob_lo,
          'recent_bull_sweep' => recent_bull_sweep,
          'recent_bear_sweep' => recent_bear_sweep,
          'liq_sweep_bull' => liq_sweep_bull,
          'liq_sweep_bear' => liq_sweep_bear,
          'ms_trend' => ms_trend,
          'tl_bear_break' => tl_bear_break,
          'tl_bull_break' => tl_bull_break,
          'tl_bear_retest' => tl_bear_retest,
          'tl_bull_retest' => tl_bull_retest,
          'sess_level_bull' => sess_level_bull,
          'sess_level_bear' => sess_level_bear,
          'vp_bull_conf' => vp_bull_conf,
          'vp_bear_conf' => vp_bear_conf,
          'near_poc' => near_poc,
          'near_vah' => near_vah,
          'near_val' => near_val,
          'long_score' => long_score,
          'short_score' => short_score,
          'long_signal' => long_signal,
          'short_signal' => short_signal,
          'pdh_sweep' => pdh_sweep,
          'pdl_sweep' => pdl_sweep,
          'pdh' => pdh,
          'pdl' => pdl,
          'poc' => poc,
          'vah' => vah,
          'val' => val_line,
          'atr14' => atr14,
          'fvg_bull_align' => fvg_bull_align,
          'fvg_bear_align' => fvg_bear_align,
          'in_discount' => in_discount,
          'in_premium' => in_premium,
          'displacement_present' => displacement_present,
          'displacement_strength' => displacement_strength,
          'displacement_range_multiple' => displacement_range_multiple,
          'displacement_volume_support' => displacement_volume_support,
          'inducement_present' => inducement_present,
          'inducement_type' => inducement_type,
          'inducement_price' => inducement_price,
          'inducement_swept' => inducement_swept,
          'mitigation_reaction_strength' => mitigation_reaction_strength
        }
      end
    end
  end
end
