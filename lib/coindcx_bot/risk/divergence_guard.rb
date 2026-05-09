# frozen_string_literal: true

require 'bigdecimal'
require_relative '../gateways/result'

module CoindcxBot
  module Risk
    # Compares Binance mid vs CoinDCX mid and rejects when spread or CoinDCX staleness exceeds limits.
    class DivergenceGuard
      def initialize(max_bps:, max_lag_ms:)
        @max_bps = BigDecimal(max_bps.to_s)
        @max_lag_ms = Integer(max_lag_ms)
        @mutex = Mutex.new
        @last_by_symbol = {}
      end

      # @param coindcx_ts [Integer] epoch milliseconds from CoinDCX (or authoritative local mid clock)
      # @param now_ms [Integer, nil] defaults to +Time.now+ in ms — inject for specs
      def check(symbol:, binance_mid:, coindcx_mid:, coindcx_ts:, max_bps: nil, max_lag_ms: nil, now_ms: nil)
        sym = symbol.to_s
        b_mid = to_bd(binance_mid)
        c_mid = to_bd(coindcx_mid)
        return Gateways::Result.err(:invalid_mid, 'missing or non-positive mids') if b_mid.nil? || c_mid.nil? || c_mid <= 0

        lag_limit = max_lag_ms ? Integer(max_lag_ms) : @max_lag_ms
        bps_limit = max_bps ? BigDecimal(max_bps.to_s) : @max_bps

        wall = now_ms ? Integer(now_ms) : (Time.now.to_f * 1000).to_i
        age = wall - Integer(coindcx_ts)
        if age > lag_limit
          cache(sym, b_mid, c_mid, coindcx_ts)
          return Gateways::Result.err(:stale_coindcx, "CoinDCX mid lag #{age}ms > #{lag_limit}ms")
        end

        bps = ((b_mid - c_mid).abs / c_mid) * BigDecimal('10000')
        if bps > bps_limit
          cache(sym, b_mid, c_mid, coindcx_ts)
          return Gateways::Result.err(:divergence_bps, "bps #{bps.to_f.round(4)} > #{bps_limit.to_f}")
        end

        cache(sym, b_mid, c_mid, coindcx_ts)
        Gateways::Result.ok(bps: bps, lag_ms: age)
      end

      def last_snapshot(symbol)
        sym = symbol.to_s
        @mutex.synchronize { @last_by_symbol[sym]&.dup }
      end

      private

      def cache(sym, b_mid, c_mid, coindcx_ts)
        @mutex.synchronize do
          @last_by_symbol[sym] = {
            binance_mid: b_mid,
            coindcx_mid: c_mid,
            coindcx_ts: Integer(coindcx_ts)
          }
        end
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
