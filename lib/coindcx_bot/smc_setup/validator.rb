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

      def validate!(raw)
        h = deep_symbolize(raw)
        missing = REQUIRED_TOP.reject { |k| h.key?(k) && !blank?(h[k]) }
        raise ValidationError, "missing keys: #{missing.join(', ')}" unless missing.empty?

        v = Integer(h[:schema_version])
        raise ValidationError, 'schema_version must be 1' unless v == 1

        sid = h[:setup_id].to_s.strip
        raise ValidationError, 'setup_id blank' if sid.empty?

        pair = h[:pair].to_s.strip
        raise ValidationError, 'pair blank' if pair.empty?

        dir = h[:direction].to_s.downcase
        raise ValidationError, "direction must be long or short (got #{dir})" unless %w[long short].include?(dir)

        cond = deep_symbolize(h[:conditions])
        sweep = deep_symbolize(cond[:sweep_zone] || {})
        entry = deep_symbolize(cond[:entry_zone] || {})
        raise ValidationError, 'conditions.sweep_zone.min/max required' unless numeric?(sweep[:min]) && numeric?(sweep[:max])
        raise ValidationError, 'conditions.entry_zone.min/max required' unless numeric?(entry[:min]) && numeric?(entry[:max])

        exec = deep_symbolize(h[:execution])
        raise ValidationError, 'execution.sl required' unless numeric?(exec[:sl])

        if h.key?(:leverage) && !blank?(h[:leverage])
          lev = Integer(h[:leverage])
          raise ValidationError, 'leverage out of range' unless lev.positive? && lev <= 125
        end

        true
      end

      def self.parse_trade_setup(raw)
        validate!(raw)
        TradeSetup.from_hash(deep_symbolize(raw))
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
