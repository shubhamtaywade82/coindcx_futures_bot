# frozen_string_literal: true

require 'bigdecimal'
require_relative 'dynamic_trail'
require_relative 'hwm_giveback'
require_relative 'hwm_price_trail'

module CoindcxBot
  module Strategy
    # Supertrend flip entries; exits via fixed TP %, DynamicTrail, HWM giveback, or stop.
    # Opposite Supertrend flips do not trigger a close — only the exit conditions above do.
    class SupertrendProfit
      def initialize(strategy_config)
        @cfg = strategy_config.transform_keys(&:to_sym)
      end

      def evaluate(pair:, candles_htf:, candles_exec:, position:, ltp:, regime_hint: nil)
        exec = candles_exec

        return manage_position(pair, position, exec, ltp) if position

        closed = exec.size >= 2 ? exec[0..-2] : []
        return hold(pair, 'insufficient_exec_bars') if closed.size < warmup_bars

        seek_entry(pair, closed, ltp || exec.last&.close)
      end

      private

      def hold(pair, reason)
        Signal.new(action: :hold, pair: pair, side: nil, stop_price: nil, reason: reason, metadata: {})
      end

      def warmup_bars
        st_period + 3
      end

      def st_period
        @cfg.fetch(:supertrend_atr_period, 10).to_i
      end

      def st_multiplier
        BigDecimal(@cfg.fetch(:supertrend_multiplier, 3).to_s)
      end

      def take_profit_pct
        BigDecimal(@cfg.fetch(:take_profit_pct, 0.10).to_s)
      end

      def stop_distance_pct_for_sizing
        BigDecimal(@cfg.fetch(:stop_distance_pct_for_sizing, 0.02).to_s)
      end

      def manage_position(pair, position, exec, ltp)
        return hold(pair, 'no_ltp') unless ltp

        entry = BigDecimal(position[:entry_price].to_s)
        return hold(pair, 'bad_entry') unless entry.positive?

        side = position[:side].to_s
        ltp_bd = BigDecimal(ltp.to_s)
        id = position[:id]

        # Stop-loss check (safety net; paper broker OCO also handles this via FillEngine).
        stop = position[:stop_price] ? BigDecimal(position[:stop_price].to_s) : nil
        if hard_stop_exits_enabled? && stop&.positive?
          if side == 'long' && ltp_bd <= stop
            return Signal.new(action: :close, pair: pair, side: :long, stop_price: nil,
                              reason: 'stop', metadata: { position_id: id })
          elsif side == 'short' && ltp_bd >= stop
            return Signal.new(action: :close, pair: pair, side: :short, stop_price: nil,
                              reason: 'stop', metadata: { position_id: id })
          end
        end

        gain =
          if side == 'long'
            (ltp_bd - entry) / entry
          elsif side == 'short'
            (entry - ltp_bd) / entry
          else
            return hold(pair, 'unknown_side')
          end

        trail = HwmPriceTrail.check(pair: pair, position: position, ltp: ltp, strategy_cfg: @cfg)
        return trail if trail

        hwm = HwmGiveback.check(pair: pair, position: position, ltp: ltp, strategy_cfg: @cfg)
        return hwm if hwm

        tp_pct = take_profit_pct
        if tp_pct.positive? && gain >= tp_pct
          return Signal.new(action: :close, pair: pair, side: side.to_sym, stop_price: nil,
                            reason: 'take_profit_pct', metadata: { position_id: id })
        end

        # Trailing stop — activates once in profit; uses same DynamicTrail tiers as TrendContinuation.
        if exec.size >= 2 && dynamic_trail_enabled?
          initial_stop = BigDecimal((position[:initial_stop_price] || position[:stop_price]).to_s)
          current_stop = stop || initial_stop
          out = trail_calculator.call(
            DynamicTrail::Input.new(
              side: side.to_sym,
              candles: exec,
              entry_price: entry,
              initial_stop: initial_stop,
              current_stop: current_stop,
              ltp: ltp_bd
            )
          )
          if out.changed
            return Signal.new(
              action: :trail,
              pair: pair,
              side: side.to_sym,
              stop_price: out.stop_price,
              reason: out.reason,
              metadata: { position_id: id, tier: out.tier, v_factor: out.v_factor,
                          vol_factor: out.vol_factor }
            )
          end
        end

        hold(pair, 'below_take_profit')
      end

      def seek_entry(pair, closed, price)
        return hold(pair, 'no_price') unless price

        price_bd = BigDecimal(price.to_s)
        trends = Indicators.supertrend_trends(closed, period: st_period, multiplier: st_multiplier)
        prev_t = trends[-2]
        cur_t = trends[-1]
        return hold(pair, 'supertrend_warmup') if prev_t.nil? || cur_t.nil?
        return hold(pair, 'no_flip') if prev_t == cur_t

        dist = stop_distance_pct_for_sizing
        one = BigDecimal('1')

        if cur_t == :bullish && prev_t == :bearish
          stop = price_bd * (one - dist)
          Signal.new(
            action: :open_long,
            pair: pair,
            side: :long,
            stop_price: stop,
            reason: 'supertrend_bull_flip',
            metadata: {}
          )
        elsif cur_t == :bearish && prev_t == :bullish
          stop = price_bd * (one + dist)
          Signal.new(
            action: :open_short,
            pair: pair,
            side: :short,
            stop_price: stop,
            reason: 'supertrend_bear_flip',
            metadata: {}
          )
        else
          hold(pair, 'no_entry_setup')
        end
      end

      def trail_calculator
        @trail_calculator ||= DynamicTrail::Calculator.new(@cfg)
      end

      def hard_stop_exits_enabled?
        v = @cfg.fetch(:exit_on_hard_stop, true)
        !(v == false || v.to_s.strip.casecmp('false').zero? || v.to_s.strip == '0')
      end

      def hwm_price_trail_enabled?
        raw = @cfg[:hwm_price_trail] || @cfg['hwm_price_trail']
        raw.is_a?(Hash) && HwmPriceTrail.truthy?(raw[:enabled] || raw['enabled'])
      end

      def dynamic_trail_enabled?
        return false if hwm_price_trail_enabled?

        v = @cfg.fetch(:dynamic_trail_enabled, true)
        !(v == false || v.to_s.strip.casecmp('false').zero? || v.to_s.strip == '0')
      end
    end
  end
end
