# frozen_string_literal: true

require 'bigdecimal'

module CoindcxBot
    module Strategy
    # Closes when unrealized PnL falls enough from the session peak (USDT), after a minimum peak is reached.
    module HwmGiveback
      DEFAULT_MIN_PEAK_USDT = BigDecimal('10')
      DEFAULT_GIVEBACK_PCT  = BigDecimal('0.35')

      def self.check(pair:, position:, ltp:, strategy_cfg:)
        cfg = extract_cfg(strategy_cfg)
        return nil unless truthy?(cfg[:enabled])

        current = UnrealizedPnl.position_usdt(position, ltp)
        return nil if current.nil?

        raw_peak = position[:peak_unrealized_usdt] || position['peak_unrealized_usdt']
        return nil if raw_peak.nil? || raw_peak.to_s.strip.empty?

        peak = BigDecimal(raw_peak.to_s)
        min_peak = decimal_or(cfg[:min_peak_usdt], DEFAULT_MIN_PEAK_USDT)
        return nil if peak < min_peak
        return nil unless peak.positive?

        pct_bd = decimal_or(cfg[:giveback_pct], DEFAULT_GIVEBACK_PCT)
        drawdown = peak - current
        pct_trigger = (drawdown / peak) >= pct_bd

        abs_raw = cfg[:giveback_usdt]
        abs_trigger =
          if abs_raw.nil? || abs_raw.to_s.strip.empty?
            false
          else
            drawdown >= BigDecimal(abs_raw.to_s)
          end

        triggered =
          if abs_raw.nil? || abs_raw.to_s.strip.empty?
            pct_trigger
          else
            pct_trigger || abs_trigger
          end

        return nil unless triggered

        drawdown_pct = (drawdown / peak * 100).round(2).to_f
        side_raw = (position[:side] || position['side']).to_s
        side_sym =
          case side_raw.downcase
          when 'long', 'buy' then :long
          when 'short', 'sell' then :short
          else :long
          end

        Signal.new(
          action: :close,
          pair: pair,
          side: side_sym,
          stop_price: nil,
          reason: 'hwm_giveback',
          metadata: {
            position_id: position[:id] || position['id'],
            peak_usdt: peak.to_s('F'),
            current_usdt: current.to_s('F'),
            drawdown_pct: drawdown_pct
          }
        )
      rescue ArgumentError, TypeError
        nil
      end

      def self.truthy?(v)
        v == true || v.to_s.downcase == 'true' || v.to_s == '1'
      end
      private_class_method :truthy?

      def self.extract_cfg(strategy_cfg)
        h = strategy_cfg || {}
        raw = h[:hwm_giveback] || h['hwm_giveback'] || {}
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
