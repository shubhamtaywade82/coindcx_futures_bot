# frozen_string_literal: true

require 'fileutils'
require 'json'

module CoindcxBot
  module Orderflow
    # Records orderbook snapshots and trades to a JSONL file for verification and backtesting.
    # Files are stored in data/orderflow_logs/session_<timestamp>.jsonl
    class Recorder
      def initialize(config:, logger: nil)
        @config = config
        @logger = logger
        @enabled = config.respond_to?(:orderflow_section) && config.orderflow_section.fetch(:record_sessions, false)
        @mutex = Mutex.new
        @file = nil
        setup_file if @enabled
      end

      def record_snapshot(pair, bids, asks)
        return unless @enabled

        write(type: :snapshot, pair: pair, bids: bids, asks: asks, ts: Time.now.to_f)
      end

      def record_trade(trade)
        return unless @enabled

        write(type: :trade, **trade, ts: Time.now.to_f)
      end

      def close
        @mutex.synchronize do
          @file&.close
          @file = nil
        end
      end

      private

      def setup_file
        dir = File.join(Dir.pwd, 'data', 'orderflow_logs')
        FileUtils.mkdir_p(dir)
        filename = "session_#{Time.now.strftime('%Y%m%d_%H%M%S')}.jsonl"
        path = File.join(dir, filename)
        @file = File.open(path, 'a')
        @file.sync = true
        @logger&.info("[orderflow:recorder] recording to #{path}")
      end

      def write(data)
        line = JSON.generate(data)
        @mutex.synchronize do
          @file&.puts(line)
        end
      rescue StandardError => e
        @logger&.warn("[orderflow:recorder] write failed: #{e.message}")
      end
    end
  end
end
