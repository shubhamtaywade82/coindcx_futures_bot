# frozen_string_literal: true

require 'bigdecimal'
require_relative '../gateways/result'
require_relative '../exchanges/binance/symbol_map'

module CoindcxBot
  module Risk
    # Compares Binance mid vs CoinDCX mid and rejects when spread or either leg exceeds staleness limits.
    class DivergenceGuard
      def initialize(max_bps:, max_lag_ms:)
        @max_bps = BigDecimal(max_bps.to_s)
        @max_lag_ms = Integer(max_lag_ms)
        @mutex = Mutex.new
        @last_by_pair = {}
      end

      # @param symbol [String] Binance symbol (e.g. +SOLUSDT+); mapped to CoinDCX pair for storage.
      def update_binance_mid(symbol:, mid:, ts:)
        pair = pair_for_binance_symbol(symbol)
        return unless pair

        m = to_bd(mid)
        return if m.nil?

        t = normalize_wall_ts(ts)
        @mutex.synchronize do
          row = @last_by_pair[pair] || {}
          row[:binance_mid] = m
          row[:binance_ts] = t
          @last_by_pair[pair] = row
        end
      end

      def update_coindcx_mid(pair:, mid:, ts:)
        sym = pair.to_s
        m = to_bd(mid)
        return if m.nil?

        t = normalize_wall_ts(ts)
        @mutex.synchronize do
          row = @last_by_pair[sym] || {}
          row[:coindcx_mid] = m
          row[:coindcx_ts] = t
          @last_by_pair[sym] = row
        end
      end

      # @param now_ms [Integer, nil] wall clock ms (inject in specs)
      # @return [Gateways::Result] ok value +{ bps:, age_ms: }+ or err value +{ reason:, bps:, age_ms: }+
      def check(pair:, now_ms: nil)
        wall = now_ms ? Integer(now_ms) : wall_now_ms
        row = @mutex.synchronize { @last_by_pair[pair.to_s]&.dup }
        return err_payload(:missing_data, 'no state for pair', nil, nil) if row.nil?

        b_mid = row[:binance_mid]
        c_mid = row[:coindcx_mid]
        b_ts = row[:binance_ts]
        c_ts = row[:coindcx_ts]

        if b_mid.nil? || c_mid.nil? || b_ts.nil? || c_ts.nil?
          return err_payload(:missing_data, 'missing binance or coindcx leg', nil, nil)
        end
        return err_payload(:missing_data, 'non-positive CoinDCX mid', nil, nil) if c_mid <= 0
        return err_payload(:missing_data, 'non-positive Binance mid', nil, nil) if b_mid <= 0

        raw_age = wall - [b_ts, c_ts].max
        age_ms = raw_age.negative? ? 0 : raw_age
        bps = bps_between(b_mid, c_mid)

        lag_b = wall - b_ts
        lag_c = wall - c_ts
        if lag_c > @max_lag_ms
          return err_payload(:coindcx_stale, "CoinDCX lag #{lag_c}ms > #{@max_lag_ms}ms", bps, age_ms)
        end
        if lag_b > @max_lag_ms
          return err_payload(:binance_stale, "Binance lag #{lag_b}ms > #{@max_lag_ms}ms", bps, age_ms)
        end
        if bps > @max_bps
          return err_payload(:max_bps_exceeded, "bps #{bps.to_f.round(4)} > #{@max_bps.to_f}", bps, age_ms)
        end

        Gateways::Result.ok(bps: bps, age_ms: age_ms)
      end

      def last_snapshot(pair)
        sym = pair.to_s
        @mutex.synchronize { @last_by_pair[sym]&.dup }
      end

      private

      def pair_for_binance_symbol(symbol)
        Exchanges::Binance::SymbolMap.to_coindcx(symbol)
      rescue Exchanges::Binance::SymbolMap::UnknownSymbol
        nil
      end

      def wall_now_ms
        (Time.now.to_f * 1000).to_i
      end

      def normalize_wall_ts(ts)
        t = Integer(ts)
        t.positive? ? t : wall_now_ms
      end

      def bps_between(b_mid, c_mid)
        ((b_mid - c_mid).abs / c_mid) * BigDecimal('10000')
      end

      def err_payload(reason, message, bps, age_ms)
        Gateways::Result.err(
          reason,
          message,
          { reason: reason, bps: bps, age_ms: age_ms }
        )
      end

      def to_bd(value)
        return nil if value.nil?

        d = value.is_a?(BigDecimal) ? value : BigDecimal(value.to_s)
        d <= 0 ? nil : d
      rescue ArgumentError, TypeError
        nil
      end
    end
  end
end
