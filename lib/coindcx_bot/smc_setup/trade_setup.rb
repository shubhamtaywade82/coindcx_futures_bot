# frozen_string_literal: true

require 'bigdecimal'

module CoindcxBot
  module SmcSetup
    # Immutable trade plan produced by Planner JSON (or tests). Evaluated by TickEvaluator.
    class TradeSetup
      attr_reader :schema_version, :setup_id, :pair, :direction, :leverage, :gatekeeper,
                  :sweep_min, :sweep_max, :entry_min, :entry_max, :confirmations, :sl, :targets, :risk_usdt

      def initialize(schema_version:, setup_id:, pair:, direction:, sweep_min:, sweep_max:, entry_min:, entry_max:,
                     confirmations:, sl:, targets:, leverage: nil, gatekeeper: false, risk_usdt: nil)
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
        freeze
      end

      def long?
        @direction == :long
      end

      def short?
        @direction == :short
      end

      def to_h
        {
          schema_version: schema_version,
          setup_id: setup_id,
          pair: pair,
          direction: direction.to_s,
          leverage: leverage,
          gatekeeper: gatekeeper,
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
      end

      def self.from_hash(h)
        h = h.transform_keys(&:to_sym)
        cond = (h[:conditions] || {}).transform_keys(&:to_sym)
        sweep = (cond[:sweep_zone] || {}).transform_keys(&:to_sym)
        entry = (cond[:entry_zone] || {}).transform_keys(&:to_sym)
        exec = (h[:execution] || {}).transform_keys(&:to_sym)
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
          risk_usdt: exec[:risk_usdt]
        )
      end
    end
  end
end
