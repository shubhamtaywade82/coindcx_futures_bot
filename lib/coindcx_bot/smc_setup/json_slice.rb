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
        raise 'no JSON object in model output' if i.nil?

        body = slice_first_json_object(s, i)
        raise 'no JSON object in model output' if body.nil? || body.strip.empty?

        parse_json_object(body)
      end

      def self.slice_first_json_object(s, brace_start)
        rng = balanced_brace_range(s, brace_start)
        return s[rng] if rng

        j = s.rindex('}')
        return nil if j.nil? || j < brace_start

        s[brace_start..j]
      end
      private_class_method :slice_first_json_object

      # First complete `{ ... }` from +brace_start+, ignoring braces inside JSON strings.
      # Avoids grabbing from first `{` to last `}` when the model appends `,`, prose, or a second object.
      def self.balanced_brace_range(s, brace_start)
        return nil unless s[brace_start] == '{'

        depth = 0
        in_string = false
        escape = false

        brace_start.upto(s.length - 1) do |idx|
          c = s[idx]
          if in_string
            if escape
              escape = false
            elsif c == '\\'
              escape = true
            elsif c == '"'
              in_string = false
            end
            next
          end

          case c
          when '"'
            in_string = true
          when '{'
            depth += 1
          when '}'
            depth -= 1
            return (brace_start..idx) if depth.zero?
          end
        end

        nil
      end
      private_class_method :balanced_brace_range

      def self.parse_json_object(body)
        json_parse(body)
      rescue JSON::ParserError
        fixed = strip_llm_trailing_commas(body)
        raise if fixed == body

        json_parse(fixed)
      end
      private_class_method :parse_json_object

      def self.json_parse(str)
        JSON.parse(str, symbolize_names: true, allow_trailing_comma: true)
      rescue ArgumentError
        JSON.parse(strip_llm_trailing_commas(str), symbolize_names: true)
      end
      private_class_method :json_parse

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
