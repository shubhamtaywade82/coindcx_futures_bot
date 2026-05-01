# frozen_string_literal: true

require 'json'

module CoindcxBot
  module Orderflow
    # Replays recorded JSONL session logs into an Orderflow::Engine for validation.
    class Replayer
      def initialize(engine:, logger: nil)
        @engine = engine
        @logger = logger
      end

      # Replays a file and returns the count of processed lines.
      def replay_file(path)
        count = 0
        File.foreach(path) do |line|
          next if line.strip.empty?

          data = JSON.parse(line, symbolize_names: true)
          process_line(data)
          count += 1
        end
        count
      rescue StandardError => e
        @logger&.error("[orderflow:replayer] failed: #{e.message}")
        0
      end

      private

      def process_line(data)
        case data[:type]&.to_sym
        when :snapshot
          @engine.on_book_update(
            pair: data[:pair],
            bids: data[:bids],
            asks: data[:asks]
          )
        when :trade
          @engine.on_trade(data)
        end
      end
    end
  end
end
