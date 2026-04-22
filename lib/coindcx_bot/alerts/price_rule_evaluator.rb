# frozen_string_literal: true

require 'bigdecimal'

module CoindcxBot
  module Alerts
    # Detects LTP zone changes vs configured above/below levels. Caller stores +last_side+ keyed by "pair|rule_id".
    class PriceRuleEvaluator
      def self.evaluate(rules:, pair:, ltp:, last_side:)
        return [] unless ltp

        ltp_bd = BigDecimal(ltp.to_s)
        pair_s = pair.to_s
        out = []

        Array(rules).each do |raw|
          next unless raw.is_a?(Hash)

          r = raw.transform_keys(&:to_sym)
          rid = (r[:id] || r[:rule_id]).to_s.strip
          rid = r[:label].to_s.strip if rid.empty?
          rid = "rule_#{pair_s}_#{out.size}" if rid.empty?

          rule_pair = (r[:pair] || r['pair']).to_s.strip
          next if rule_pair.empty? || rule_pair != pair_s

          above = decimal_or_nil(r[:above] || r['above'])
          below = decimal_or_nil(r[:below] || r['below'])
          next if above.nil? && below.nil?

          state_key = "#{pair_s}|#{rid}"
          zone = zone_for(ltp_bd, above: above, below: below)
          prev = last_side[state_key]
          last_side[state_key] = zone

          next if prev.nil?
          next if prev == zone

          direction = "#{prev}→#{zone}"
          level =
            if above && below
              "between #{below.to_s('F')} and #{above.to_s('F')}"
            elsif above
              "above #{above.to_s('F')}"
            else
              "below #{below.to_s('F')}"
            end

          out << {
            rule_id: rid,
            pair: pair_s,
            direction: direction,
            price: ltp_bd.to_s('F'),
            level: level,
            label: (r[:label] || r['label']).to_s.strip,
            from_zone: prev.to_s,
            to_zone: zone.to_s,
            dedupe_key: "#{state_key}:#{zone}"
          }
        end
        out
      end

      def self.zone_for(ltp_bd, above:, below:)
        if above && below
          return :below if ltp_bd < below
          return :above if ltp_bd > above

          :between
        elsif above
          ltp_bd > above ? :above : :at_or_below
        elsif below
          ltp_bd < below ? :below : :at_or_above
        else
          :unknown
        end
      end

      def self.decimal_or_nil(v)
        return nil if v.nil? || v.to_s.strip.empty?

        BigDecimal(v.to_s)
      rescue ArgumentError, TypeError
        nil
      end
    end
  end
end
