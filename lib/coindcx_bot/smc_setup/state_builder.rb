# frozen_string_literal: true

require 'time'

module CoindcxBot
  module SmcSetup
    # Transforms SmcConfluence::BarResult and internal engine state into the
    # structured JSON state snapshot expected by the AI Planner.
    module StateBuilder
      module_function

      CANDLE_VALIDITY = { '5m' => 8, '15m' => 5, '1h' => 2, '4h' => 1, '1d' => 1 }.freeze
      TIMEFRAME_SECONDS = { '5m' => 300, '15m' => 900, '1h' => 3600, '4h' => 14_400, '1d' => 86_400 }.freeze

      def build(pair:, bar_result:, candles:, timeframe:)
        last_candle = candles.last
        close = last_candle[:close].to_f

        {
          pair: pair,
          time: time_block(last_candle, timeframe),
          structure: structure_block(bar_result),
          liquidity: liquidity_block(bar_result),
          smc: smc_block(bar_result),
          volume_profile: volume_profile_block(bar_result),
          volatility: { atr14: bar_result.atr14 },
          mean: mean_block(bar_result, close),
          orderflow: { exchange_delta_available: false, note: 'delta/cum_delta not available from REST candles' },
          execution: execution_block(bar_result, candles),
          state: state_flags(bar_result, candles),
          price: { close: close }
        }
      end

      def time_block(last_candle, timeframe)
        valid_candles = CANDLE_VALIDITY[timeframe] || 5
        tf_seconds    = TIMEFRAME_SECONDS[timeframe] || 900
        expires_at    = (Time.now.utc + (valid_candles * tf_seconds)).iso8601
        {
          timeframe: timeframe,
          timestamp: last_candle[:timestamp],
          server_time: Time.now.utc.iso8601,
          valid_candles: valid_candles,
          expires_at: expires_at
        }
      end

      def structure_block(bar_result)
        {
          trend: bar_result.structure_bias == 1 ? 'uptrend' : (bar_result.structure_bias == -1 ? 'downtrend' : 'range'),
          ms_trend: bar_result.ms_trend == 1 ? 'bullish' : (bar_result.ms_trend == -1 ? 'bearish' : 'neutral'),
          bos: {
            bullish: bar_result.bos_bull,
            bearish: bar_result.bos_bear
          },
          choch: {
            bullish: bar_result.choch_bull,
            bearish: bar_result.choch_bear
          }
        }
      end

      def liquidity_block(bar_result)
        {
          recent_sweep: {
            bullish: bar_result.recent_bull_sweep,
            bearish: bar_result.recent_bear_sweep
          },
          event: bar_result.liq_sweep_bull ? 'bull_sweep' : (bar_result.liq_sweep_bear ? 'bear_sweep' : 'none'),
          pdh: bar_result.pdh,
          pdl: bar_result.pdl,
          pdh_sweep: bar_result.pdh_sweep,
          pdl_sweep: bar_result.pdl_sweep
        }
      end

      def smc_block(bar_result)
        {
          displacement: displacement_block(bar_result),
          inducement: inducement_block(bar_result),
          mitigation: mitigation_block(bar_result),
          order_blocks: build_order_blocks(bar_result),
          fvg: {
            bullish_align: bar_result.fvg_bull_align,
            bearish_align: bar_result.fvg_bear_align
          },
          premium_discount: {
            in_discount: bar_result.in_discount,
            in_premium: bar_result.in_premium,
            label: premium_discount_label(bar_result)
          }
        }
      end

      def displacement_block(bar_result)
        {
          present: bar_result.displacement_present,
          strength: bar_result.displacement_strength,
          range_multiple: bar_result.displacement_range_multiple,
          volume_support: bar_result.displacement_volume_support
        }
      end

      def inducement_block(bar_result)
        {
          present: bar_result.inducement_present,
          type: bar_result.inducement_type,
          price: bar_result.inducement_price,
          swept: bar_result.inducement_swept
        }
      end

      def mitigation_block(bar_result)
        zone = active_ob_zone(bar_result)
        status =
          if zone
            bar_result.in_bull_ob || bar_result.in_bear_ob ? 'partial' : 'untouched'
          else
            'none'
          end
        { status: status, zone: zone, reaction_strength: bar_result.mitigation_reaction_strength }
      end

      def active_ob_zone(bar_result)
        if bar_result.bull_ob_valid && bar_result.bull_ob_hi && bar_result.bull_ob_lo
          hi = bar_result.bull_ob_hi.to_f
          lo = bar_result.bull_ob_lo.to_f
          return [lo, hi].minmax
        end
        if bar_result.bear_ob_valid && bar_result.bear_ob_hi && bar_result.bear_ob_lo
          hi = bar_result.bear_ob_hi.to_f
          lo = bar_result.bear_ob_lo.to_f
          return [lo, hi].minmax
        end

        nil
      end

      def premium_discount_label(bar_result)
        return 'premium' if bar_result.in_premium
        return 'discount' if bar_result.in_discount

        'equilibrium'
      end

      def volume_profile_block(bar_result)
        {
          poc: bar_result.poc,
          vah: bar_result.vah,
          val: bar_result.val_line,
          near_poc: bar_result.near_poc,
          near_vah: bar_result.near_vah,
          near_val: bar_result.near_val
        }
      end

      def mean_block(bar_result, close)
        vwap_pos = if bar_result.vah && close > bar_result.vah
                     'above'
                   elsif bar_result.val_line && close < bar_result.val_line
                     'below'
                   elsif bar_result.vah || bar_result.val_line
                     'at'
                   else
                     'unknown'
                   end
        { vwap_position: vwap_pos }
      end

      def execution_block(bar_result, candles)
        last = candles.last
        {
          entry_model: {
            ltf_choch: bar_result.choch_bull || bar_result.choch_bear,
            ltf_bos: bar_result.bos_bull || bar_result.bos_bear,
            rejection: rejection_candle?(last),
            type: entry_type(bar_result)
          }
        }
      end

      def rejection_candle?(candle)
        return false if candle.nil?

        high  = candle[:high].to_f
        low   = candle[:low].to_f
        open  = candle[:open].to_f
        close = candle[:close].to_f
        range = high - low
        return false if range <= 0

        upper_wick = high - [open, close].max
        lower_wick = [open, close].min - low
        ([upper_wick, lower_wick].max / range) >= 0.5
      end

      def entry_type(bar_result)
        return 'ob' if bar_result.in_bull_ob || bar_result.in_bear_ob
        return 'fvg' if bar_result.fvg_bull_align || bar_result.fvg_bear_align
        return 'liquidity' if bar_result.sess_level_bull || bar_result.sess_level_bear

        'none'
      end

      def state_flags(bar_result, candles)
        atr14 = bar_result.atr14.to_f
        low_atr = low_atr_regime?(atr14, candles)
        {
          is_range: bar_result.structure_bias.to_i.zero?,
          is_trending: !bar_result.structure_bias.to_i.zero?,
          is_liquidity_event: bar_result.liq_sweep_bull || bar_result.liq_sweep_bear,
          is_post_sweep: bar_result.recent_bull_sweep || bar_result.recent_bear_sweep,
          is_pre_expansion: low_atr && (bar_result.in_bull_ob || bar_result.in_bear_ob)
        }
      end

      def low_atr_regime?(current_atr, candles)
        return false if current_atr <= 0 || candles.size < 20

        window = candles.last(20)
        highs  = window.map { |c| c[:high].to_f }
        lows   = window.map { |c| c[:low].to_f }
        ranges = highs.zip(lows).map { |h, l| h - l }
        avg_range = ranges.sum / ranges.size
        avg_range.positive? && current_atr < avg_range * 0.8
      end

      def build_order_blocks(bar_result)
        obs = []
        if bar_result.bull_ob_valid && bar_result.bull_ob_hi && bar_result.bull_ob_lo
          lo = bar_result.bull_ob_lo.to_f
          hi = bar_result.bull_ob_hi.to_f
          obs << { type: 'bullish', zone: [lo, hi].minmax, tf: 'execution' }
        end
        if bar_result.bear_ob_valid && bar_result.bear_ob_hi && bar_result.bear_ob_lo
          lo = bar_result.bear_ob_lo.to_f
          hi = bar_result.bear_ob_hi.to_f
          obs << { type: 'bearish', zone: [lo, hi].minmax, tf: 'execution' }
        end
        obs
      end
    end
  end
end
