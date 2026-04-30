# frozen_string_literal: true

require 'json'

module CoindcxBot
  module Regime
    # JSON bundle produced offline (e.g. scripts/train_ml_regime.py) for Ruby inference.
    class MlModelBundle
      SCHEMA_VERSION = 1
      SUPPORTED_TYPES = %w[multinomial_logistic].freeze
      ALLOWED_TIERS = %w[low_vol mid_vol high_vol].freeze

      attr_reader :schema_version, :model_type, :feature_order, :classes, :weights, :biases, :tier_by_class

      def self.from_json(json_string)
        new(JSON.parse(json_string, symbolize_names: true))
      end

      def self.from_file(path)
        from_json(File.read(path))
      end

      def initialize(hash)
        h = hash.transform_keys(&:to_sym)
        @schema_version = Integer(h.fetch(:schema_version))
        raise ArgumentError, "unsupported schema_version #{@schema_version}" unless @schema_version == SCHEMA_VERSION

        @model_type = h.fetch(:model_type).to_s
        raise ArgumentError, "unsupported model_type #{@model_type}" unless SUPPORTED_TYPES.include?(@model_type)

        @feature_order = Array(h.fetch(:feature_order)).map(&:to_s)
        @classes = Array(h.fetch(:classes)).map(&:to_s)
        @weights = Array(h.fetch(:weights)).map { |row| Array(row).map(&:to_f) }
        @biases = Array(h.fetch(:biases)).map(&:to_f)
        @tier_by_class = h.fetch(:tier_by_class).transform_keys(&:to_s).transform_values(&:to_s)

        validate_shape!
        validate_tiers!
      end

      def feature_dimension
        @feature_order.size
      end

      def class_count
        @classes.size
      end

      private

      def validate_shape!
        d = feature_dimension
        raise ArgumentError, 'feature_order cannot be empty' if d < 1

        k = class_count
        raise ArgumentError, 'classes cannot be empty' if k < 2

        raise ArgumentError, "weights rows #{@weights.size} != #{k}" unless @weights.size == k

        @weights.each_with_index do |row, i|
          raise ArgumentError, "weights[#{i}] len #{row.size} != #{d}" unless row.size == d
        end

        raise ArgumentError, "biases len #{@biases.size} != #{k}" unless @biases.size == k
      end

      def validate_tiers!
        @classes.each do |c|
          raise ArgumentError, "tier_by_class missing #{c.inspect}" unless @tier_by_class.key?(c)

          t = @tier_by_class[c]
          raise ArgumentError, "invalid tier #{t.inspect} for #{c}" unless ALLOWED_TIERS.include?(t)
        end
      end
    end
  end
end
