# frozen_string_literal: true

require 'bigdecimal'
require_relative 'dynamic_trail'
require_relative 'hwm_giveback'

module CoindcxBot
  module Strategy
    class TrendContinuation
      def initialize(strategy_config)
        @cfg = strategy_config.transform_keys(&:to_sym)
      end

      def evaluate(pair:, candles_htf:, candles_exec:, position:, ltp:, regime_hint: nil)
        exec = candles_exec
        htf = candles_htf
        return hold(pair, 'insufficient_exec_bars') if exec.size < warmup_exec
        return hold(pair, 'insufficient_htf_bars') if htf.size < warmup_htf

        trend = regime(htf, exec)
        return hold(pair, 'no_regime') unless trend

        strength = Indicators.ema_atr_ratio(
          exec,
          fast: ef,
          slow: es,
          atr_period: atr_p
        )
        return hold(pair, 'weak_trend_strength') if strength.nil? || strength < trend_strength_min

        last = exec.last
        price = ltp || last.close

        return manage_open(pair, position, exec, price, trend) if position

        gate = entry_filters(pair, exec, trend)
        return gate if gate

        seek_entry(pair, exec, price, trend)
      end

      private

      def hold(pair, reason)
        Signal.new(action: :hold, pair: pair, side: nil, stop_price: nil, reason: reason, metadata: {})
      end

      def warmup_exec
        [@cfg.fetch(:compression_lookback, 8).to_i + @cfg.fetch(:breakout_lookback, 4).to_i + es + 5, 40].max
      end

      def warmup_htf
        [@cfg.fetch(:ema_slow, 26).to_i + 5, 35].max
      end

      def ef
        @cfg.fetch(:ema_fast, 12).to_i
      end

      def es
        @cfg.fetch(:ema_slow, 26).to_i
      end

      def atr_p
        @cfg.fetch(:atr_period, 14).to_i
      end

      def trend_strength_min
        BigDecimal(@cfg.fetch(:trend_strength_min, 0.12).to_s)
      end

      def entry_filters(pair, exec, trend)
        if volume_filter_on?
          ratio = Indicators.volume_ratio_last(exec, lookback: volume_lookback)
          min_r = volume_min_ratio
          return hold(pair, 'volume_gate') if ratio.nil? || ratio < min_r
        end

        bars = structure_bars
        if bars.positive? && !Indicators.directional_structure?(exec, trend, bars: bars)
          return hold(pair, 'structure_gate')
        end

        adx_min = adx_min_threshold
        if adx_min.positive?
          adx = Indicators.adx_last(exec, period: adx_period)
          return hold(pair, 'adx_gate') if adx.nil? || adx < adx_min
        end

        nil
      end

      def volume_filter_on?
        !!@cfg[:volume_filter]
      end

      def volume_lookback
        @cfg.fetch(:volume_lookback, 20).to_i
      end

      def volume_min_ratio
        BigDecimal(@cfg.fetch(:volume_min_ratio, 1.0).to_s)
      end

      def structure_bars
        @cfg.fetch(:structure_bars, 0).to_i
      end

      def adx_period
        @cfg.fetch(:adx_period, 14).to_i
      end

      def adx_min_threshold
        BigDecimal(@cfg.fetch(:adx_min, 0).to_s)
      end

      def regime(htf, exec)
        h_closes = htf.map(&:close)
        e_closes = exec.map(&:close)
        h_fast = Indicators.ema_last(h_closes, ef)
        h_slow = Indicators.ema_last(h_closes, es)
        e_fast = Indicators.ema_last(e_closes, ef)
        e_slow = Indicators.ema_last(e_closes, es)
        return nil unless h_fast && h_slow && e_fast && e_slow

        last_h = h_closes.last
        last_e = e_closes.last

        if h_fast > h_slow && last_h > h_slow && e_fast > e_slow && last_e > e_slow
          :long
        elsif h_fast < h_slow && last_h < h_slow && e_fast < e_slow && last_e < e_slow
          :short
        end
      end

      def seek_entry(pair, exec, price, trend)
        lookback = @cfg.fetch(:compression_lookback, 8).to_i
        ratio = BigDecimal(@cfg.fetch(:compression_ratio, 0.65).to_s)
        brk_n = @cfg.fetch(:breakout_lookback, 4).to_i
        tol = BigDecimal(@cfg.fetch(:pullback_ema_tolerance_pct, 0.0025).to_s)

        slice = exec.last(lookback)
        range_h = slice.map(&:high).max
        range_l = slice.map(&:low).min
        avg_range = slice.sum { |c| c.high - c.low } / lookback
        compressed = avg_range.positive? && (slice.last.high - slice.last.low) < avg_range * ratio

        recent_high = exec.last(brk_n).map(&:high).max
        recent_low = exec.last(brk_n).map(&:low).min
        atr_val = Indicators.atr(exec, atr_p) || BigDecimal('0')

        if trend == :long
          stop = price - (atr_val * BigDecimal('2'))
          if compressed && price > range_h
            return Signal.new(action: :open_long, pair: pair, side: :long, stop_price: stop,
                              reason: 'breakout_after_compression', metadata: {})
          end
          ema_f = Indicators.ema_last(exec.map(&:close), ef)
          if ema_f && exec.size >= 2 && exec[-2].low <= ema_f * (BigDecimal('1') + tol) && price > ema_f && price > recent_high * BigDecimal('0.999')
            return Signal.new(action: :open_long, pair: pair, side: :long, stop_price: stop,
                              reason: 'pullback_to_ema', metadata: {})
          end
        else
          stop = price + (atr_val * BigDecimal('2'))
          if compressed && price < range_l
            return Signal.new(action: :open_short, pair: pair, side: :short, stop_price: stop,
                              reason: 'breakout_after_compression', metadata: {})
          end
          ema_f = Indicators.ema_last(exec.map(&:close), ef)
          if ema_f && exec.size >= 2 && exec[-2].high >= ema_f * (BigDecimal('1') - tol) && price < ema_f && price < recent_low * BigDecimal('1.001')
            return Signal.new(action: :open_short, pair: pair, side: :short, stop_price: stop,
                              reason: 'pullback_to_ema', metadata: {})
          end
        end

        hold(pair, 'no_entry_setup')
      end

      def manage_open(pair, position, exec, price, trend)
        side = position[:side].to_sym
        entry = BigDecimal(position[:entry_price].to_s)
        stop = BigDecimal(position[:stop_price].to_s)
        partial = position[:partial_done].to_i == 1
        id = position[:id]

        opposing = (trend == :long && side == :short) || (trend == :short && side == :long)
        if opposing
          return Signal.new(action: :close, pair: pair, side: side, stop_price: nil, reason: 'trend_failure',
                            metadata: { position_id: id })
        end

        if side == :long
          return close_signal(pair, side, id, 'stop') if hard_stop_exits_enabled? && price <= stop

          hwm = HwmGiveback.check(pair: pair, position: position, ltp: price, strategy_cfg: @cfg)
          return hwm if hwm

          risk = entry - stop
          if !partial && risk.positive? && price >= entry + risk
            return Signal.new(action: :partial, pair: pair, side: side, stop_price: nil, reason: 'one_r',
                              metadata: { position_id: id })
          end

          initial_stop = BigDecimal((position[:initial_stop_price] || position[:stop_price]).to_s)
          out = trail_calculator.call(
            DynamicTrail::Input.new(
              side: :long,
              candles: exec,
              entry_price: entry,
              initial_stop: initial_stop,
              current_stop: stop,
              ltp: price
            )
          )
          if out.changed
            return Signal.new(
              action: :trail,
              pair: pair,
              side: side,
              stop_price: out.stop_price,
              reason: out.reason,
              metadata: {
                position_id: id,
                tier: out.tier,
                v_factor: out.v_factor,
                vol_factor: out.vol_factor
              }
            )
          end
        else
          return close_signal(pair, side, id, 'stop') if hard_stop_exits_enabled? && price >= stop

          hwm = HwmGiveback.check(pair: pair, position: position, ltp: price, strategy_cfg: @cfg)
          return hwm if hwm

          risk = stop - entry
          if !partial && risk.positive? && price <= entry - risk
            return Signal.new(action: :partial, pair: pair, side: side, stop_price: nil, reason: 'one_r',
                              metadata: { position_id: id })
          end

          initial_stop = BigDecimal((position[:initial_stop_price] || position[:stop_price]).to_s)
          out = trail_calculator.call(
            DynamicTrail::Input.new(
              side: :short,
              candles: exec,
              entry_price: entry,
              initial_stop: initial_stop,
              current_stop: stop,
              ltp: price
            )
          )
          if out.changed
            return Signal.new(
              action: :trail,
              pair: pair,
              side: side,
              stop_price: out.stop_price,
              reason: out.reason,
              metadata: {
                position_id: id,
                tier: out.tier,
                v_factor: out.v_factor,
                vol_factor: out.vol_factor
              }
            )
          end
        end

        hold(pair, 'position_ok')
      end

      def hard_stop_exits_enabled?
        v = @cfg.fetch(:exit_on_hard_stop, true)
        !(v == false || v.to_s.strip.casecmp('false').zero? || v.to_s.strip == '0')
      end

      def close_signal(pair, side, id, reason)
        Signal.new(action: :close, pair: pair, side: side, stop_price: nil, reason: reason,
                   metadata: { position_id: id })
      end

      def trail_calculator
        @trail_calculator ||= DynamicTrail::Calculator.new(@cfg)
      end
    end
  end
end
