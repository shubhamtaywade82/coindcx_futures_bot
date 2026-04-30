# frozen_string_literal: true

require_relative 'smc_snapshot'

module CoindcxBot
  module TradingAi
    # Deterministic OHLCV-derived features for AI prompts (additive to SMC/DTW hashes).
    # Does not re-run full SMC replay; pass `smc` from {SmcSnapshot.from_bar_result} or caller.
    class FeatureEnricher
      Candle = Struct.new(:timestamp, :open, :high, :low, :close, :volume, keyword_init: true) do
        def range
          high - low
        end

        def body
          (close - open).abs
        end

        def bullish?
          close > open
        end

        def bearish?
          close < open
        end

        def body_efficiency
          return 0.0 if range <= 0.0

          body / range
        end

        def upper_wick
          high - [open, close].max
        end

        def lower_wick
          [open, close].min - low
        end

        def tp
          (high + low + close) / 3.0
        end
      end

      DEFAULTS = {
        volume_short: 5,
        volume_long: 20,
        momentum_lookback: 10,
        position_lookback: 100,
        atr_period: 14,
        volatility_lookback: 50,
        max_target_count: 3,
        fees_buffer_pct: 0.35,
        trailing_activation_pct: 15.0
      }.freeze

      def self.call(candles:, smc:, dtw: {}, history: [], entry: nil, stop_loss: nil, targets: [],
                    symbol: nil, timeframe: nil, tz_offset_minutes: 0, options: {}, clock: nil)
        new(
          candles: candles,
          smc: smc,
          dtw: dtw,
          history: history,
          entry: entry,
          stop_loss: stop_loss,
          targets: targets,
          symbol: symbol,
          timeframe: timeframe,
          tz_offset_minutes: tz_offset_minutes,
          options: options,
          clock: clock
        ).call
      end

      def initialize(candles:, smc:, dtw:, history:, entry:, stop_loss:, targets:,
                     symbol:, timeframe:, tz_offset_minutes:, options:, clock:)
        @candles = normalize_candles(candles)
        @smc = deep_symbolize(smc || {})
        @dtw = deep_symbolize(dtw || {})
        @history = Array(history)
        @entry = entry
        @stop_loss = stop_loss
        @targets = Array(targets).compact.first(DEFAULTS[:max_target_count])
        @symbol = symbol
        @timeframe = timeframe
        @tz_offset_minutes = tz_offset_minutes.to_i
        @options = DEFAULTS.merge(options || {})
        @clock = clock || -> { Time.now.utc }
      end

      def call
        raise ArgumentError, 'candles cannot be empty' if @candles.empty?

        atr_s = atr_series(@candles, @options[:atr_period])
        vwap_s = vwap_series(@candles)
        volume_series = @candles.map(&:volume)
        close_series = @candles.map(&:close)
        volatility = volatility_features(atr_series: atr_s, lookback: @options[:volatility_lookback])
        volume = volume_features(volume_series: volume_series, close_series: close_series)
        candle = candle_features(@candles.last, atr_s.last, volume_series)
        session = session_features(@candles.last.timestamp, @tz_offset_minutes)
        positioning = positioning_features(vwap_series: vwap_s, lookback: @options[:position_lookback])
        momentum = momentum_features(atr_series: atr_s, lookback: @options[:momentum_lookback])
        statistics = statistics_features
        risk = risk_features(atr: atr_s.last, volatility: volatility)
        trade_quality = trade_quality_features(statistics: statistics, risk: risk)
        conflicts = conflict_matrix(momentum: momentum, volume: volume)

        {
          symbol: @symbol,
          timeframe: @timeframe,
          price: @candles.last.close,
          smc: @smc,
          dtw: @dtw,
          volatility: volatility,
          volume: volume,
          candle: candle,
          session: session,
          positioning: positioning,
          momentum: momentum,
          statistics: statistics,
          trade_quality: trade_quality,
          conflicts: conflicts,
          risk: risk,
          meta: {
            candle_count: @candles.size,
            last_timestamp: @candles.last.timestamp,
            enriched_at: @clock.call.iso8601
          }
        }
      end

      private

      def normalize_candles(candles)
        Array(candles).each_with_index.map do |c, idx|
          next c if c.is_a?(Candle)

          h = deep_symbolize(c.is_a?(Hash) ? c : {})
          ts = h[:timestamp] || h[:time]
          Candle.new(
            timestamp: normalize_time(ts, synthetic_index: idx),
            open: (h[:open] || h[:o]).to_f,
            high: (h[:high] || h[:h]).to_f,
            low: (h[:low] || h[:l]).to_f,
            close: (h[:close] || h[:c]).to_f,
            volume: (h[:volume] || h[:v] || 0).to_f
          )
        end
      end

      def normalize_time(value, synthetic_index: 0)
        return value.utc if value.is_a?(Time)

        return Time.at(value).utc if value.is_a?(Integer)

        return Time.at(synthetic_index * 60).utc if value.nil?

        Time.parse(value.to_s).utc if value.respond_to?(:to_s)
      rescue ArgumentError, TypeError
        Time.at(synthetic_index * 60).utc
      end

      def deep_symbolize(obj)
        case obj
        when Hash
          obj.each_with_object({}) do |(k, v), acc|
            acc[k.to_sym] = deep_symbolize(v)
          end
        when Array
          obj.map { |v| deep_symbolize(v) }
        else
          obj
        end
      end

      def mean(values)
        return 0.0 if values.empty?

        values.sum.to_f / values.size
      end

      def sma_series(values, period)
        return [] if values.empty?

        out = []
        values.each_index do |i|
          window = values[[0, i - period + 1].max..i]
          out << mean(window)
        end
        out
      end

      def atr_series(candles, period)
        trs = candles.each_with_index.map do |c, i|
          if i.zero?
            c.high - c.low
          else
            prev = candles[i - 1]
            [c.high - c.low, (c.high - prev.close).abs, (c.low - prev.close).abs].max
          end
        end
        sma_series(trs, period)
      end

      def vwap_series(candles)
        cum_tp_vol = 0.0
        cum_vol = 0.0
        candles.map do |c|
          cum_tp_vol += c.tp * c.volume
          cum_vol += c.volume
          cum_vol.positive? ? (cum_tp_vol / cum_vol) : c.close
        end
      end

      def percentile_rank(series, value)
        return 0.0 if series.empty?

        less_or_equal = series.count { |v| v <= value }
        (less_or_equal.to_f / series.size) * 100.0
      end

      def clamp(x, lo, hi)
        [[x, lo].max, hi].min
      end

      def volatility_features(atr_series:, lookback:)
        atrs = atr_series.last([lookback, atr_series.size].min).compact
        current_atr = atr_series.last.to_f
        atr_percentile = percentile_rank(atrs, current_atr)
        regime =
          if atr_percentile >= 75.0
            'high'
          elsif atr_percentile <= 25.0
            'low'
          else
            'normal'
          end

        recent_atr_mean = mean(atrs.last([5, atrs.size].min))
        prior_window = atrs.size > 5 ? atrs[0..-(6)] : atrs
        prior_atr_mean = prior_window.empty? ? recent_atr_mean : mean(prior_window)

        look = [lookback, @candles.size].min
        recent = @candles.last(look)
        compression_breakout =
          prior_atr_mean.positive? &&
          recent_atr_mean > prior_atr_mean * 1.25 &&
          @candles.last.close > recent.map(&:high).max

        {
          regime: regime,
          atr: current_atr.round(6),
          atr_percentile: atr_percentile.round(2),
          compression_breakout: compression_breakout,
          atr_trend: current_atr > prior_atr_mean ? 'expanding' : 'contracting'
        }
      end

      def volume_features(volume_series:, close_series:)
        short_n = [@options[:volume_short], volume_series.size].min
        long_n = [@options[:volume_long], volume_series.size].min
        short_avg = mean(volume_series.last(short_n))
        long_avg = mean(volume_series.last(long_n))

        volume_trend =
          if short_avg > long_avg * 1.05
            'increasing'
          elsif short_avg < long_avg * 0.95
            'decreasing'
          else
            'flat'
          end

        first_c = close_series.first.to_f
        last_c = close_series.last.to_f
        price_trend =
          if last_c > first_c
            'up'
          elsif last_c < first_c
            'down'
          else
            'flat'
          end

        price_volume_alignment =
          (price_trend == 'up' && volume_trend == 'increasing') ||
          (price_trend == 'down' && volume_trend == 'increasing') ||
          volume_trend == 'flat'

        last = @candles.last
        vol_window = @candles.last([50, @candles.size].min).map(&:volume)
        range_window = @candles.last([50, @candles.size].min).map(&:range)
        vol_percentile = percentile_rank(vol_window, last.volume)
        range_percentile = percentile_rank(range_window, last.range)
        climax = vol_percentile >= 90.0 && range_percentile >= 80.0
        absorption_zone_active = vol_percentile >= 80.0 && last.body_efficiency <= 0.25

        {
          trend: volume_trend,
          price_trend: price_trend,
          price_volume_alignment: price_volume_alignment,
          climax: climax,
          absorption_zone_active: absorption_zone_active,
          volume_percentile: vol_percentile.round(2),
          range_percentile: range_percentile.round(2),
          short_avg: short_avg.round(6),
          long_avg: long_avg.round(6)
        }
      end

      def candle_features(last, atr_value, _volume_series)
        last_atr = [atr_value.to_f, 0.0001].max
        upper_wick_pct = (last.upper_wick / [last.range, 0.0001].max) * 100.0
        lower_wick_pct = (last.lower_wick / [last.range, 0.0001].max) * 100.0
        body_eff = last.body_efficiency

        rejection =
          if upper_wick_pct >= 55.0 && last.bearish?
            'bearish'
          elsif lower_wick_pct >= 55.0 && last.bullish?
            'bullish'
          else
            'none'
          end

        compression = body_eff <= 0.25 && last.range < last_atr * 0.5
        momentum_candle = body_eff >= 0.65 && last.range > last_atr * 0.75

        {
          upper_wick_pct: upper_wick_pct.round(2),
          lower_wick_pct: lower_wick_pct.round(2),
          body_efficiency: body_eff.round(4),
          rejection: rejection,
          compression: compression,
          momentum_candle: momentum_candle
        }
      end

      # Exclusive local-time buckets (UTC + offset): Asia 00–08, London 08–13, NY 13–22, off otherwise.
      def session_features(timestamp, tz_offset_minutes)
        local = timestamp.utc + (tz_offset_minutes * 60)
        minutes = (local.hour * 60) + local.min

        current =
          if minutes >= 0 && minutes < 8 * 60
            'asia'
          elsif minutes >= 8 * 60 && minutes < 13 * 60
            'london'
          elsif minutes >= 13 * 60 && minutes < 22 * 60
            'ny'
          else
            'off_session'
          end

        phase = session_phase_for(current, minutes)
        expansion_expected = %w[london ny].include?(current) && phase == 'open'

        {
          current: current,
          phase: phase,
          expansion_expected: expansion_expected,
          timestamp_utc: timestamp.utc.iso8601
        }
      end

      def session_phase_for(current, minutes)
        case current
        when 'asia'
          rel = minutes # 0 .. 8h
          phase_from_elapsed(rel, open_mins: 120, mid_mins: 240)
        when 'london'
          rel = minutes - (8 * 60) # 0 .. 5h
          phase_from_elapsed(rel, open_mins: 120, mid_mins: 210)
        when 'ny'
          rel = minutes - (13 * 60) # 0 .. 9h
          phase_from_elapsed(rel, open_mins: 90, mid_mins: 360)
        else
          'inactive'
        end
      end

      def phase_from_elapsed(rel, open_mins:, mid_mins:)
        return 'open' if rel < open_mins
        return 'mid' if rel < mid_mins

        'close'
      end

      def positioning_features(vwap_series:, lookback:)
        recent = @candles.last([lookback, @candles.size].min)
        highest = recent.map(&:high).max
        lowest = recent.map(&:low).min
        last = @candles.last
        vwap = vwap_series.last.to_f

        range_percentile =
          if (highest - lowest) > 0.0
            ((last.close - lowest) / (highest - lowest)) * 100.0
          else
            50.0
          end

        premium_discount =
          if (highest - lowest) > 0.0
            (last.close - lowest) / (highest - lowest)
          else
            0.5
          end

        distance_from_vwap_pct =
          if vwap > 0.0
            ((last.close - vwap) / vwap) * 100.0
          else
            0.0
          end

        mean_close = mean(recent.map(&:close))
        distance_from_mean_pct =
          if mean_close > 0.0
            ((last.close - mean_close) / mean_close) * 100.0
          else
            0.0
          end

        {
          range_percentile: range_percentile.round(2),
          premium_discount: premium_discount.round(4),
          distance_from_vwap_pct: distance_from_vwap_pct.round(4),
          distance_from_mean_pct: distance_from_mean_pct.round(4)
        }
      end

      def momentum_features(atr_series:, lookback:)
        recent = @candles.last([lookback, @candles.size].min)
        last = @candles.last
        atr = [atr_series.last.to_f, 0.0001].max
        body_to_atr = last.body / atr
        impulse =
          if body_to_atr >= 1.0
            'strong'
          elsif body_to_atr >= 0.6
            'moderate'
          else
            'weak'
          end

        consecutive_bull = count_consecutive_from_end { |c| c.bullish? }
        consecutive_bear = count_consecutive_from_end { |c| c.bearish? }

        decelerating = decelerating_move?(recent)

        {
          impulse: impulse,
          consecutive_bull_candles: consecutive_bull,
          consecutive_bear_candles: consecutive_bear,
          decelerating: decelerating,
          body_to_atr: body_to_atr.round(4)
        }
      end

      def count_consecutive_from_end
        n = 0
        @candles.reverse_each do |c|
          break unless yield(c)

          n += 1
        end
        n
      end

      def decelerating_move?(recent)
        bodies = recent.map(&:body)
        vols = recent.map(&:volume)
        return false if bodies.size < 6

        half = bodies.size / 2
        first_half = mean(bodies.first(half))
        second_half = mean(bodies.last(half))
        first_vol = mean(vols.first(half))
        second_vol = mean(vols.last(half))
        second_half < first_half * 0.9 && second_vol < first_vol * 0.9
      end

      def setup_class
        bias = (@smc[:htf_bias] || @smc[:bias]).to_s.downcase
        if bias == 'bull' && @dtw[:whale_buy]
          'bull_accumulation'
        elsif bias == 'bear' && @dtw[:whale_sell]
          'bear_distribution'
        elsif @dtw[:exhaustion]
          'exhaustion'
        elsif @dtw[:iceberg]
          'absorption'
        else
          'neutral'
        end
      end

      def statistics_features
        relevant = @history.select do |h|
          h = deep_symbolize(h)
          h[:setup_class].to_s == setup_class
        end

        wins = relevant.count { |h| deep_symbolize(h)[:win] == true }
        total = relevant.size
        win_rate = total.positive? ? wins.to_f / total : 0.0

        rr_values = relevant.map { |h| deep_symbolize(h)[:rr] }.compact.map(&:to_f)
        tp1_hits = relevant.count { |h| deep_symbolize(h)[:tp1_hit] == true }

        avg_rr = rr_values.any? ? mean(rr_values) : 0.0
        tp1_hit_prob = total.positive? ? tp1_hits.to_f / total : 0.0

        {
          setup_class: setup_class,
          sample_size: total,
          win_rate: win_rate.round(4),
          avg_rr: avg_rr.round(4),
          tp1_hit_prob: tp1_hit_prob.round(4)
        }
      end

      def risk_features(atr:, volatility:)
        atr = atr.to_f
        entry = @entry&.to_f
        stop_loss = @stop_loss&.to_f
        first_target = @targets.first&.to_f

        sl_distance_pct =
          if entry && stop_loss && entry > 0.0
            ((entry - stop_loss).abs / entry) * 100.0
          else
            0.0
          end

        sl_volatility_ratio =
          if atr > 0.0 && entry && stop_loss
            (entry - stop_loss).abs / atr
          else
            0.0
          end

        target_distance_pct =
          if entry && first_target && entry > 0.0
            ((first_target - entry).abs / entry) * 100.0
          else
            0.0
          end

        {
          atr: atr.round(6),
          stop_loss_distance_pct: sl_distance_pct.round(4),
          sl_volatility_ratio: sl_volatility_ratio.round(4),
          first_target_distance_pct: target_distance_pct.round(4),
          suggested_trailing_activation_pct: @options[:trailing_activation_pct],
          fees_buffer_pct: @options[:fees_buffer_pct],
          volatility_regime: volatility[:regime]
        }
      end

      def trade_quality_features(statistics:, risk:)
        entry = @entry&.to_f
        stop_loss = @stop_loss&.to_f
        first_target = @targets.first&.to_f

        rr =
          if entry && stop_loss && first_target && (entry - stop_loss).abs > 0.0
            (first_target - entry).abs / (entry - stop_loss).abs
          else
            0.0
          end

        win_rate = statistics[:win_rate].to_f
        avg_rr = statistics[:avg_rr].to_f
        expected_edge_pct = (win_rate * avg_rr - (1.0 - win_rate)) * 100.0

        quality =
          if rr >= 2.0 && win_rate >= 0.55 && expected_edge_pct > 0.0
            'strong'
          elsif rr >= 1.5
            'moderate'
          else
            'weak'
          end

        {
          rr: rr.round(4),
          expected_edge_pct: expected_edge_pct.round(4),
          sl_volatility_ratio: risk[:sl_volatility_ratio],
          quality: quality
        }
      end

      def trend_from_smc
        b = (@smc[:htf_bias] || @smc[:bias]).to_s.downcase
        return 'bull' if b == 'bull'
        return 'bear' if b == 'bear'

        'neutral'
      end

      def conflict_matrix(momentum:, volume:)
        bull_structure = trend_from_smc == 'bull'
        bear_structure = trend_from_smc == 'bear'

        dtw_bull = !!@dtw[:whale_buy] || @dtw[:delta_bull] == true
        dtw_bear = !!@dtw[:whale_sell] || @dtw[:delta_bear] == true

        {
          smc_bull_vs_dtw_distribution: bull_structure && dtw_bear,
          smc_bear_vs_dtw_accumulation: bear_structure && dtw_bull,
          momentum_vs_structure: (
            (bull_structure && momentum[:impulse] == 'weak' && momentum[:decelerating]) ||
            (bear_structure && momentum[:impulse] == 'weak' && momentum[:decelerating])
          ),
          volume_vs_price: volume[:price_volume_alignment] == false,
          exhaustion_vs_bias: @dtw[:exhaustion] == true,
          divergence_vs_direction: divergence_conflict?(bull_structure, bear_structure)
        }
      end

      def divergence_conflict?(bull_structure, bear_structure)
        div = @dtw[:delta_divergence].to_s.downcase
        (bull_structure && div == 'bearish') || (bear_structure && div == 'bullish')
      end
    end
  end
end
