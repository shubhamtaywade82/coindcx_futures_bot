# frozen_string_literal: true

module CoindcxBot
  module TradingAi
    # Maps authoritative {SmcConfluence::BarResult} into a flat hash for {FeatureEnricher}
    # and AI prompts — avoids re-deriving SMC from raw OHLCV.
    module SmcSnapshot
      module_function

      def from_bar_result(bar)
        return {} if bar.nil?

        bias =
          case bar.structure_bias.to_i
          when 1 then 'bull'
          when -1 then 'bear'
          else 'neutral'
          end

        liq =
          if bar.liq_sweep_bull
            'bullish'
          elsif bar.liq_sweep_bear
            'bearish'
          else
            'none'
          end

        vp =
          if bar.near_poc
            'near_poc'
          elsif bar.near_vah
            'near_vah'
          elsif bar.near_val
            'near_val'
          else
            'none'
          end

        {
          htf_bias: bias,
          ms_trend: bar.ms_trend,
          bos: bar.bos_bull || bar.bos_bear,
          choch: bar.choch_bull || bar.choch_bear,
          bull_ob: bar.in_bull_ob && bar.bull_ob_valid,
          bear_ob: bar.in_bear_ob && bar.bear_ob_valid,
          liq_sweep: liq,
          vp_context: vp,
          long_score: bar.long_score,
          short_score: bar.short_score,
          fvg_bull_align: bar.fvg_bull_align,
          fvg_bear_align: bar.fvg_bear_align,
          in_discount: bar.in_discount,
          in_premium: bar.in_premium,
          atr14: bar.atr14
        }
      end
    end
  end
end
