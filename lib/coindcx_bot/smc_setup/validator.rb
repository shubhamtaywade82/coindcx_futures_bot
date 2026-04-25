# frozen_string_literal: true

require_relative 'trade_setup'

module CoindcxBot
  module SmcSetup
    # Minimal structural validation (no json_schemer dependency).
    class Validator
      class ValidationError < StandardError; end

      REQUIRED_TOP = %i[schema_version setup_id pair direction conditions execution].freeze

      def self.validate!(hash)
        new.validate!(hash)
      end

      # @return [Hash] deep-symbolized payload (optional fields like +invalidation_level+ may be nil'd in place)
      def validate!(raw)
        h = deep_symbolize(raw)
        sanitize_optional_top_level_fields!(h)
        
        sid = h[:setup_id].to_s.strip
        pair = h[:pair].to_s.strip
        ctx = "[setup_id:#{sid.empty? ? 'unknown' : sid} pair:#{pair.empty? ? 'unknown' : pair}]"

        missing = REQUIRED_TOP.reject { |k| h.key?(k) && !blank?(h[k]) }
        raise ValidationError, "#{ctx} missing keys: #{missing.join(', ')}" unless missing.empty?

        v = Integer(h[:schema_version])
        raise ValidationError, "#{ctx} schema_version must be 1" unless v == 1

        dir = h[:direction].to_s.downcase
        raise ValidationError, "#{ctx} direction must be long or short (got #{dir})" unless %w[long short].include?(dir)

        cond = deep_symbolize(h[:conditions])
        sweep = deep_symbolize(cond[:sweep_zone] || {})
        entry = deep_symbolize(cond[:entry_zone] || {})
        raise ValidationError, "#{ctx} conditions.sweep_zone.min/max required" unless numeric?(sweep[:min]) && numeric?(sweep[:max])
        raise ValidationError, "#{ctx} conditions.entry_zone.min/max required" unless numeric?(entry[:min]) && numeric?(entry[:max])

        exec = deep_symbolize(h[:execution])
        raise ValidationError, "#{ctx} execution.sl required" unless numeric?(exec[:sl])

        if h.key?(:leverage) && !blank?(h[:leverage])
          lev = Integer(h[:leverage])
          raise ValidationError, "#{ctx} leverage out of range" unless lev.positive? && lev <= 125
        end

        if h.key?(:valid_for_minutes) && !blank?(h[:valid_for_minutes])
          vfm = Integer(h[:valid_for_minutes])
          raise ValidationError, "#{ctx} valid_for_minutes must be positive" unless vfm.positive?
        end

        nt = deep_symbolize(cond[:no_trade_zone] || {})
        if nt.any? { |_k, v| !blank?(v) }
          raise ValidationError, "#{ctx} conditions.no_trade_zone requires min and max" unless numeric?(nt[:min]) && numeric?(nt[:max])
        end

        h
      end

      def self.parse_trade_setup(raw)
        h = validate!(raw)
        TradeSetup.from_hash(h)
      end

      def self.deep_symbolize(obj)
        Validator.deep_symbolize(obj)
      end

      def self.deep_symbolize(obj)
        case obj
        when Hash
          obj.each_with_object({}) { |(k, v), m| m[k.to_sym] = deep_symbolize(v) }
        when Array
          obj.map { |e| deep_symbolize(e) }
        else
          obj
        end
      end

      private

      # Planner / LLM often emits placeholders; +TradeSetup+ treats bad values as absent via +optional_bigdecimal+.
      def sanitize_optional_top_level_fields!(h)
        return unless h.is_a?(Hash)
        return unless h.key?(:invalidation_level)

        v = h[:invalidation_level]
        return if blank?(v)
        return if numeric?(v)

        h[:invalidation_level] = nil
      end

      def deep_symbolize(obj)
        self.class.deep_symbolize(obj)
      end

      def blank?(v)
        v.nil? || (v.respond_to?(:empty?) && v.empty?)
      end

      def numeric?(v)
        Float(v)
        true
      rescue ArgumentError, TypeError
        false
      end
    end
  end
end
