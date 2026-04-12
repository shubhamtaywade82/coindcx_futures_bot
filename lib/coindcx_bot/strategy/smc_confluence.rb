# frozen_string_literal: true

require 'bigdecimal'
require_relative 'signal'

module CoindcxBot
  module Strategy
    # Entries from {SmcConfluence::Engine} (Pine-parity SMC-CE). Configure via +strategy.smc_confluence+ in bot.yml.
    class SmcConfluence
      def initialize(strategy_config)
        @cfg = strategy_config.transform_keys(&:to_sym)
        @smc_cfg = ::CoindcxBot::SmcConfluence::Configuration.from_hash(@cfg[:smc_confluence])
      end

      def evaluate(pair:, candles_htf:, candles_exec:, position:, ltp:, regime_hint: nil)
        exec = candles_exec
        return hold(pair, 'insufficient_exec_bars') if exec.size < min_exec_bars

        if position
          return manage_open(pair, position, ltp, exec)
        end

        rows = ::CoindcxBot::SmcConfluence::Candles.from_dto(exec)
        series = ::CoindcxBot::SmcConfluence::Engine.run(rows, configuration: @smc_cfg)
        last = series.last
        return hold(pair, 'no_smc_bar') unless last

        price = BigDecimal((ltp || exec.last.close).to_s)
        return hold(pair, 'no_price') unless price.positive?

        meta = smc_metadata(last)

        if last.long_signal && !htf_blocks_entry?(:long, candles_htf)
          stop = stop_for_long(price)
          Signal.new(
            action: :open_long,
            pair: pair,
            side: :long,
            stop_price: stop,
            reason: 'smc_long_signal',
            metadata: meta
          )
        elsif last.short_signal && !htf_blocks_entry?(:short, candles_htf)
          stop = stop_for_short(price)
          Signal.new(
            action: :open_short,
            pair: pair,
            side: :short,
            stop_price: stop,
            reason: 'smc_short_signal',
            metadata: meta
          )
        elsif last.long_signal && htf_blocks_entry?(:long, candles_htf)
          hold(pair, smc_htf_reason(:long, last), metadata: meta)
        elsif last.short_signal && htf_blocks_entry?(:short, candles_htf)
          hold(pair, smc_htf_reason(:short, last), metadata: meta)
        else
          hold(pair, smc_hold_reason(last), metadata: meta)
        end
      end

      private

      def hold(pair, reason, metadata: {})
        Signal.new(action: :hold, pair: pair, side: nil, stop_price: nil, reason: reason, metadata: metadata)
      end

      def min_exec_bars
        [@smc_cfg.vp_bars, @smc_cfg.smc_swing * 4 + 10, @smc_cfg.ms_swing * 4 + 10, @smc_cfg.liq_lookback + 5, 50].max
      end

      def stop_distance_pct
        BigDecimal(@cfg.fetch(:stop_distance_pct_for_sizing, 0.02).to_s)
      end

      def take_profit_pct
        BigDecimal(@cfg.fetch(:take_profit_pct, 0).to_s)
      end

      def stop_for_long(price)
        price * (BigDecimal('1') - stop_distance_pct)
      end

      def stop_for_short(price)
        price * (BigDecimal('1') + stop_distance_pct)
      end

      def htf_alignment?
        truthy?(@cfg[:htf_alignment])
      end

      def htf_blocks_entry?(side, candles_htf)
        return false unless htf_alignment?

        htf = Array(candles_htf)
        return false if htf.size < min_exec_bars

        rows = ::CoindcxBot::SmcConfluence::Candles.from_dto(htf)
        last = ::CoindcxBot::SmcConfluence::Engine.run(rows, configuration: @smc_cfg).last
        return true unless last

        if side == :long
          !(last.structure_bias == 1 || last.ms_trend == 1)
        else
          !(last.structure_bias == -1 || last.ms_trend == -1)
        end
      end

      def truthy?(v)
        v == true || v.to_s.downcase == 'true' || v.to_s == '1'
      end

      def smc_metadata(last)
        {
          long_score: last.long_score,
          short_score: last.short_score,
          choch_bull: last.choch_bull,
          choch_bear: last.choch_bear,
          bos_bull: last.bos_bull,
          bos_bear: last.bos_bear
        }
      end

      def primary_long?(last)
        @smc_cfg.bos_relaxed? ? (last.choch_bull || last.bos_bull) : last.choch_bull
      end

      def primary_short?(last)
        @smc_cfg.bos_relaxed? ? (last.choch_bear || last.bos_bear) : last.choch_bear
      end

      def smc_htf_reason(side, last)
        min = @smc_cfg.min_score
        if side == :long
          "smc_htf_xL L#{last.long_score}/#{min}"
        else
          "smc_htf_xS S#{last.short_score}/#{min}"
        end
      end

      # TUI-friendly: scores + min + situation (primary weak vs no primary vs cooldown-style gate).
      def smc_hold_reason(last)
        min = @smc_cfg.min_score
        ls = last.long_score
        ss = last.short_score
        pl = primary_long?(last)
        ps = primary_short?(last)

        if pl && ls >= min
          return "smc_l_cd L#{ls}/#{min}" # CE did not flag long_signal — usually bar cooldown inside engine
        end
        if ps && ss >= min
          return "smc_s_cd S#{ss}/#{min}"
        end
        return "smc_l_weak L#{ls}/#{min}" if pl && ls < min
        return "smc_s_weak S#{ss}/#{min}" if ps && ss < min

        "smc_flat L#{ls}S#{ss}·#{min}"
      end

      def manage_open(pair, position, ltp, exec)
        return hold(pair, 'no_ltp') unless ltp

        side = position[:side].to_s
        entry = BigDecimal(position[:entry_price].to_s)
        return hold(pair, 'bad_entry') unless entry.positive?

        ltp_bd = BigDecimal(ltp.to_s)
        id = position[:id]

        if side == 'long' && opposite_fire?(exec, :short)
          return Signal.new(action: :close, pair: pair, side: :long, stop_price: nil, reason: 'smc_opposite_short',
                            metadata: { position_id: id })
        end
        if side == 'short' && opposite_fire?(exec, :long)
          return Signal.new(action: :close, pair: pair, side: :short, stop_price: nil, reason: 'smc_opposite_long',
                            metadata: { position_id: id })
        end

        tp = take_profit_pct
        if tp.positive?
          gain =
            if side == 'long'
              (ltp_bd - entry) / entry
            elsif side == 'short'
              (entry - ltp_bd) / entry
            else
              return hold(pair, 'unknown_side')
            end
          if gain >= tp
            return Signal.new(action: :close, pair: pair, side: side.to_sym, stop_price: nil, reason: 'smc_take_profit_pct',
                              metadata: { position_id: id })
          end
        end

        hold(pair, 'smc_in_pos')
      end

      def opposite_fire?(exec, direction)
        rows = ::CoindcxBot::SmcConfluence::Candles.from_dto(exec)
        last = ::CoindcxBot::SmcConfluence::Engine.run(rows, configuration: @smc_cfg).last
        return false unless last

        direction == :long ? last.long_signal : last.short_signal
      end
    end
  end
end
