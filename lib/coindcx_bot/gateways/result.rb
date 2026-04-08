# frozen_string_literal: true

module CoindcxBot
  module Gateways
    class Result
      def self.ok(value = nil)
        new(ok: true, value: value, code: nil, message: nil)
      end

      def self.fail(code, message, value = nil)
        new(ok: false, value: value, code: code, message: message)
      end

      attr_reader :value, :code, :message

      def initialize(ok:, value:, code:, message:)
        @ok = ok
        @value = value
        @code = code
        @message = message
      end

      def ok?
        @ok
      end

      def failure?
        !@ok
      end
    end
  end
end
