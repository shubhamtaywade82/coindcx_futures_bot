# frozen_string_literal: true

module CoindcxBot
  module SmcConfluence
    # Defaults match delta_exchange_bot `smc_confluence.pine` / Configuration (no ENV — use YAML or .new).
    class Configuration
      attr_reader :smc_swing, :ob_body_pct, :ob_expire, :liq_lookback, :liq_wick_pct,
                  :ms_swing, :tl_pivot_len, :tl_retest_pct, :vp_bars, :vp_rows,
                  :poc_zone_pct, :sess_liq_pct, :min_score, :sig_cooldown, :atr_period,
                  :signal_mode

      # signal_mode: :choch_strict (Pine parity) or :bos_relaxed (BOS or CHOCH counts as primary trigger for score gate)
      def initialize(
        smc_swing: 10,
        ob_body_pct: 0.3,
        ob_expire: 50,
        liq_lookback: 20,
        liq_wick_pct: 0.1,
        ms_swing: 10,
        tl_pivot_len: 10,
        tl_retest_pct: 0.15,
        vp_bars: 100,
        vp_rows: 24,
        poc_zone_pct: 0.2,
        sess_liq_pct: 0.1,
        min_score: 3,
        sig_cooldown: 5,
        atr_period: 14,
        signal_mode: :choch_strict
      )
        @smc_swing = Integer(smc_swing)
        @ob_body_pct = Float(ob_body_pct)
        @ob_expire = Integer(ob_expire)
        @liq_lookback = Integer(liq_lookback)
        @liq_wick_pct = Float(liq_wick_pct)
        @ms_swing = Integer(ms_swing)
        @tl_pivot_len = Integer(tl_pivot_len)
        @tl_retest_pct = Float(tl_retest_pct)
        @vp_bars = Integer(vp_bars)
        @vp_rows = Integer(vp_rows)
        @poc_zone_pct = Float(poc_zone_pct)
        @sess_liq_pct = Float(sess_liq_pct)
        @min_score = Integer(min_score)
        @sig_cooldown = Integer(sig_cooldown)
        @atr_period = Integer(atr_period)
        @signal_mode = normalize_signal_mode(signal_mode)
      end

      def bos_relaxed?
        @signal_mode == :bos_relaxed
      end

      def self.from_hash(h)
        return new if h.nil? || (h.respond_to?(:empty?) && h.empty?)

        sym = h.transform_keys { |k| k.to_sym }
        new(**slice_known_keys(sym))
      end

      def self.slice_known_keys(sym)
        {
          smc_swing: sym[:smc_swing],
          ob_body_pct: sym[:ob_body_pct],
          ob_expire: sym[:ob_expire],
          liq_lookback: sym[:liq_lookback],
          liq_wick_pct: sym[:liq_wick_pct],
          ms_swing: sym[:ms_swing],
          tl_pivot_len: sym[:tl_pivot_len],
          tl_retest_pct: sym[:tl_retest_pct],
          vp_bars: sym[:vp_bars],
          vp_rows: sym[:vp_rows],
          poc_zone_pct: sym[:poc_zone_pct],
          sess_liq_pct: sym[:sess_liq_pct],
          min_score: sym[:min_score],
          sig_cooldown: sym[:sig_cooldown],
          atr_period: sym[:atr_period],
          signal_mode: sym[:signal_mode]
        }.compact
      end

      private

      def normalize_signal_mode(raw)
        s = raw.to_s.strip.downcase
        return :bos_relaxed if s == 'bos_relaxed' || s == 'bos'

        :choch_strict
      end
    end
  end
end
