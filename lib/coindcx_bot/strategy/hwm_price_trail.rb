# frozen_string_literal: true

require 'bigdecimal'

module CoindcxBot
  module Strategy
    # Exit after a favorable price run-up, using a peak price (HWM for longs, LWM for shorts).
    # The trail does nothing until peak return from entry reaches +activate_gain_pct+, then closes
    # when price pulls back +pullback_from_peak_pct+ from that peak.
    module HwmPriceTrail
      DEFAULT_ACTIVATE_GAIN_PCT = BigDecimal('0.15')
      DEFAULT_PULLBACK_PCT = BigDecimal('0.05')

      def self.check(pair:, position:, ltp:, strategy_cfg:)
        cfg = extract_cfg(strategy_cfg)
        return nil unless truthy?(cfg[:enabled])

        entry = BigDecimal((position[:entry_price] || position['entry_price']).to_s)
        return nil unless entry.positive?

        ltp_bd = BigDecimal(ltp.to_s)
        side_raw = (position[:side] || position['side']).to_s.downcase
        activate = decimal_or(cfg[:activate_gain_pct], DEFAULT_ACTIVATE_GAIN_PCT)
        pullback = decimal_or(cfg[:pullback_from_peak_pct], DEFAULT_PULLBACK_PCT)

        raw_peak = position[:peak_ltp] || position['peak_ltp']
        peak =
          if raw_peak.nil? || raw_peak.to_s.strip.empty?
            entry
          else
            BigDecimal(raw_peak.to_s)
          end

        max_favorable =
          case side_raw
          when 'long', 'buy'
            (peak - entry) / entry
          when 'short', 'sell'
            (entry - peak) / entry
          else
            return nil
          end

        return nil if max_favorable < activate

        triggered =
          case side_raw
          when 'long', 'buy'
            ltp_bd <= peak * (BigDecimal('1') - pullback)
          when 'short', 'sell'
            ltp_bd >= peak * (BigDecimal('1') + pullback)
          else
            false
          end

        return nil unless triggered

        side_sym = %w[long buy].include?(side_raw) ? :long : :short
        pid = position[:id] || position['id']

        Signal.new(
          action: :close,
          pair: pair,
          side: side_sym,
          stop_price: nil,
          reason: 'hwm_price_trail',
          metadata: {
            position_id: pid,
            peak_price: peak.to_s('F'),
            activate_gain_pct: activate.to_s('F'),
            pullback_from_peak_pct: pullback.to_s('F')
          }
        )
      rescue ArgumentError, TypeError
        nil
      end

      def self.truthy?(v)
        v == true || v.to_s.downcase == 'true' || v.to_s == '1'
      end

      def self.extract_cfg(strategy_cfg)
        h = strategy_cfg || {}
        raw = h[:hwm_price_trail] || h['hwm_price_trail'] || {}
        raw.is_a?(Hash) ? raw.transform_keys(&:to_sym) : {}
      end
      private_class_method :extract_cfg

      def self.decimal_or(raw, default)
        return default if raw.nil? || raw.to_s.strip.empty?

        BigDecimal(raw.to_s)
      rescue ArgumentError, TypeError
        default
      end
      private_class_method :decimal_or
    end
  end
end
