# frozen_string_literal: true

require 'json'

module CoindcxBot
  module Orderflow
    # Replays recorded JSONL session logs into an Orderflow::Engine for validation.
    class Replayer
      def initialize(engine:, logger: nil, only_source: nil)
        @engine = engine
        @logger = logger
        @only_source = only_source&.to_sym
      end

      # Replays a file and returns the count of processed lines.
      def replay_file(path)
        count = 0
        File.foreach(path) do |line|
          next if line.strip.empty?

          data = JSON.parse(line, symbolize_names: true)
          next if skip_line_for_source_filter?(data)

          process_line(data)
          count += 1
        end
        count
      rescue StandardError => e
        @logger&.error("[orderflow:replayer] failed: #{e.message}")
        0
      end

      private

      def skip_line_for_source_filter?(data)
        return false unless @only_source

        line_src = (data[:source] || data['source'] || :coindcx).to_sym
        line_src != @only_source
      end

      def line_source(data)
        (data[:source] || data['source'] || :coindcx).to_sym
      end

      def process_line(data)
        src = line_source(data)
        case data[:type]&.to_sym
        when :snapshot
          @engine.on_book_update(
            pair: data[:pair],
            bids: data[:bids],
            asks: data[:asks],
            source: src
          )
        when :trade
          @engine.on_trade(data.except(:type))
        end
      end
    end
  end
end
