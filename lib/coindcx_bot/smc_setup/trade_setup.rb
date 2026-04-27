# frozen_string_literal: true

require 'bigdecimal'

module CoindcxBot
  module SmcSetup
    # Immutable trade plan produced by Planner JSON (or tests). Evaluated by TickEvaluator.
    class TradeSetup
      attr_reader :schema_version, :setup_id, :pair, :direction, :leverage, :gatekeeper,
                  :sweep_min, :sweep_max, :entry_min, :entry_max, :confirmations, :sl, :targets, :risk_usdt,
                  :valid_for_minutes, :expires_at, :invalidation_level, :no_trade_min, :no_trade_max

      def initialize(schema_version:, setup_id:, pair:, direction:, sweep_min:, sweep_max:, entry_min:, entry_max:,
                     confirmations:, sl:, targets:, leverage: nil, gatekeeper: false, risk_usdt: nil,
                     valid_for_minutes: nil, expires_at: nil, invalidation_level: nil,
                     no_trade_min: nil, no_trade_max: nil)
        @schema_version = Integer(schema_version)
        @setup_id = setup_id.to_s.freeze
        @pair = pair.to_s.freeze
        @direction = direction.to_s.downcase.to_sym
        @leverage = leverage&.to_i
        @gatekeeper = !!gatekeeper
        @sweep_min = BigDecimal(sweep_min.to_s)
        @sweep_max = BigDecimal(sweep_max.to_s)
        @entry_min = BigDecimal(entry_min.to_s)
        @entry_max = BigDecimal(entry_max.to_s)
        @confirmations = Array(confirmations).map(&:to_s).freeze
        @sl = BigDecimal(sl.to_s)
        @targets = Array(targets).map { |x| BigDecimal(x.to_s) }.freeze
        @risk_usdt = risk_usdt.nil? ? nil : BigDecimal(risk_usdt.to_s)
        @valid_for_minutes = valid_for_minutes&.to_i
        @expires_at = self.class.parse_time_utc(expires_at)
        @invalidation_level = self.class.optional_bigdecimal(invalidation_level)
        @no_trade_min = self.class.optional_bigdecimal(no_trade_min)
        @no_trade_max = self.class.optional_bigdecimal(no_trade_max)

        if @valid_for_minutes&.positive? && !@expires_at
          @expires_at = Time.now.utc + (@valid_for_minutes * 60)
        end
        freeze
      end

      def self.parse_time_utc(raw)
        return nil if raw.nil? || (raw.respond_to?(:empty?) && raw.empty?)

        Time.parse(raw.to_s).utc
      rescue ArgumentError, TypeError
        nil
      end

      def self.optional_bigdecimal(v)
        return nil if v.nil? || (v.respond_to?(:empty?) && v.empty?)

        BigDecimal(v.to_s)
      rescue ArgumentError, TypeError
        nil
      end

      def expired?
        @expires_at && Time.now.utc > @expires_at
      end

      def in_no_trade_zone?(price)
        return false unless @no_trade_min && @no_trade_max

        lo = [@no_trade_min, @no_trade_max].min
        hi = [@no_trade_min, @no_trade_max].max
        price >= lo && price <= hi
      end

      def breached_invalidation?(price)
        return false unless @invalidation_level

        if long?
          price <= @invalidation_level
        elsif short?
          price >= @invalidation_level
        else
          false
        end
      end

      def valid_geometry?
        return false if targets.empty?

        if long?
          # Long: SL < Entry < TP
          return false unless sl < entry_min
          targets.all? { |t| t > entry_max }
        elsif short?
          # Short: TP < Entry < SL
          return false unless sl > entry_max
          targets.all? { |t| t < entry_min }
        else
          false
        end
      end

      def rr_ratio
        return 0.0 if targets.empty? || entry_min == sl

        entry_avg = (entry_min + entry_max) / 2.0
        risk = (entry_avg - sl).abs
        reward = (targets.first - entry_avg).abs
        return 0.0 if risk.zero?

        (reward / risk).to_f.round(2)
      end

      def long?
        @direction == :long
      end

      def short?
        @direction == :short
      end

      def to_h
        h = {
          schema_version: schema_version,
          setup_id: setup_id,
          pair: pair,
          direction: direction.to_s,
          leverage: leverage,
          gatekeeper: gatekeeper,
          valid_for_minutes: valid_for_minutes,
          expires_at: expires_at&.iso8601,
          invalidation_level: invalidation_level&.to_f,
          conditions: {
            sweep_zone: { min: sweep_min.to_f, max: sweep_max.to_f },
            entry_zone: { min: entry_min.to_f, max: entry_max.to_f },
            confirmation_required: confirmations
          },
          execution: {
            sl: sl.to_f,
            targets: targets.map(&:to_f),
            risk_usdt: risk_usdt&.to_f
          }.compact
        }
        if no_trade_zone_present?
          h[:conditions][:no_trade_zone] = {
            min: no_trade_min.to_f,
            max: no_trade_max.to_f
          }
        end
        h
      end

      def event_payload
        {
          setup_id: setup_id,
          pair: pair,
          direction: direction.to_s,
          entry_min: entry_min.to_f.to_s,
          entry_max: entry_max.to_f.to_s,
          sweep_min: sweep_min.to_f.to_s,
          sweep_max: sweep_max.to_f.to_s,
          sl: sl.to_f.to_s,
          targets: targets.map(&:to_f).map(&:to_s).join(','),
          risk_usdt: risk_usdt&.to_f.to_s,
          leverage: leverage.to_s,
          gatekeeper: gatekeeper.to_s,
          confirmations: confirmations.to_s,
          expires_at: expires_at&.iso8601.to_s
        }
      end

      def self.from_hash(h)
        h = h.transform_keys(&:to_sym)
        cond = (h[:conditions] || {}).transform_keys(&:to_sym)
        sweep = (cond[:sweep_zone] || {}).transform_keys(&:to_sym)
        entry = (cond[:entry_zone] || {}).transform_keys(&:to_sym)
        exec = (h[:execution] || {}).transform_keys(&:to_sym)
        nt = (cond[:no_trade_zone] || {}).transform_keys(&:to_sym)
        new(
          schema_version: h.fetch(:schema_version),
          setup_id: h.fetch(:setup_id),
          pair: h.fetch(:pair),
          direction: h.fetch(:direction),
          sweep_min: sweep.fetch(:min),
          sweep_max: sweep.fetch(:max),
          entry_min: entry.fetch(:min),
          entry_max: entry.fetch(:max),
          confirmations: Array(cond[:confirmation_required]),
          sl: exec.fetch(:sl),
          targets: Array(exec[:targets]),
          leverage: h[:leverage],
          gatekeeper: h[:gatekeeper],
          risk_usdt: exec[:risk_usdt],
          valid_for_minutes: h[:valid_for_minutes],
          expires_at: h[:expires_at],
          invalidation_level: h[:invalidation_level],
          no_trade_min: nt[:min],
          no_trade_max: nt[:max]
        )
      end

      def event_payload
        {
          setup_id: setup_id,
          pair: pair,
          direction: direction.to_s,
          entry_min: entry_min.to_f,
          entry_max: entry_max.to_f,
          sl: sl.to_f,
          targets: targets.map(&:to_f).join(','),
          risk_usdt: risk_usdt&.to_f,
          leverage: leverage,
          expires_at: expires_at&.iso8601
        }.compact
      end

      private

      def no_trade_zone_present?
        @no_trade_min && @no_trade_max
      end
    end
  end
end
