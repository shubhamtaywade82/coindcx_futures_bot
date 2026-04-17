# frozen_string_literal: true

require 'json'

module CoindcxBot
  module SmcSetup
    module JsonSlice
      module_function

      TRAILING_COMMA_BEFORE_CLOSE = /,(\s*[}\]])/

      def parse_object(raw)
        s = raw.to_s.strip
        # Strip <think>...</think> reasoning blocks that may contain intermediate { or }
        s = s.gsub(%r{<think>.*?</think>}m, '')
        s = s.sub(/\A```(?:json)?\s*/i, '').sub(/```\s*\z/m, '')
        i = s.index('{')
        j = s.rindex('}')
        raise 'no JSON object in model output' if i.nil? || j.nil? || j < i

        parse_json_object(s[i..j])
      end

      def self.parse_json_object(body)
        JSON.parse(body, symbolize_names: true)
      rescue JSON::ParserError
        JSON.parse(strip_llm_trailing_commas(body), symbolize_names: true)
      end
      private_class_method :parse_json_object

      def self.strip_llm_trailing_commas(json)
        out = json
        loop do
          next_out = out.gsub(TRAILING_COMMA_BEFORE_CLOSE, '\1')
          break next_out if next_out == out

          out = next_out
        end
      end
      private_class_method :strip_llm_trailing_commas
    end
  end
end
