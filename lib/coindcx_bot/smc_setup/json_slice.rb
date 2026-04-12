# frozen_string_literal: true

require 'json'

module CoindcxBot
  module SmcSetup
    module JsonSlice
      module_function

      def parse_object(raw)
        s = raw.to_s.strip
        s = s.sub(/\A```(?:json)?\s*/i, '').sub(/```\s*\z/m, '')
        i = s.index('{')
        j = s.rindex('}')
        raise 'no JSON object in model output' if i.nil? || j.nil? || j < i

        JSON.parse(s[i..j], symbolize_names: true)
      end
    end
  end
end
