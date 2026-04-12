# frozen_string_literal: true

require 'bigdecimal'
require_relative 'hwm_giveback'

module CoindcxBot
  module Strategy
    # 5m (or any `execution_resolution`) Supertrend entries; exits only at configured take-profit % on price.
    # Opposite Supertrend flips do not close — only the profit target does.
    class SupertrendProfit
      def initialize(strategy_config)
        @cfg = strategy_config.transform_keys(&:to_sym)
      end

      def evaluate(pair:, candles_htf:, candles_exec:, position:, ltp:, regime_hint: nil)
        exec = candles_exec

        return manage_position(pair, position, ltp) if position

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

      def manage_position(pair, position, ltp)
        return hold(pair, 'no_ltp') unless ltp

        entry = BigDecimal(position[:entry_price].to_s)
        return hold(pair, 'bad_entry') unless entry.positive?

        side = position[:side].to_s
        gain =
          if side == 'long'
            (BigDecimal(ltp.to_s) - entry) / entry
          elsif side == 'short'
            (entry - BigDecimal(ltp.to_s)) / entry
          else
            return hold(pair, 'unknown_side')
          end

        hwm = HwmGiveback.check(pair: pair, position: position, ltp: ltp, strategy_cfg: @cfg)
        return hwm if hwm

        if gain >= take_profit_pct
          id = position[:id]
          return Signal.new(
            action: :close,
            pair: pair,
            side: side.to_sym,
            stop_price: nil,
            reason: 'take_profit_pct',
            metadata: { position_id: id }
          )
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
    end
  end
end
