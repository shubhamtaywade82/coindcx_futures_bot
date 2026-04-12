# frozen_string_literal: true

require 'json'
require_relative 'validator'
require_relative 'states'

module CoindcxBot
  module SmcSetup
    StoredRecord = Struct.new(:setup_id, :pair, :state, :trade_setup, :eval_state, keyword_init: true)

    class TradeSetupStore
      def initialize(journal:, max_active_setups_per_pair: 3, external_lock: nil)
        @journal = journal
        @max_per_pair = max_active_setups_per_pair
        @lock = external_lock || Mutex.new
        @by_pair = {}
      end

      def reload!
        @lock.synchronize do
          @by_pair = {}
          @journal.smc_setup_load_active.each do |row|
            rec = build_record(row)
            next unless rec

            @by_pair[rec.pair] ||= []
            @by_pair[rec.pair] << rec
          end
        end
      end

      def records_for_pair(pair)
        @lock.synchronize { Array(@by_pair[pair.to_s]) }
      end

      def pair_has_actionable?(pair)
        records_for_pair(pair).any? { |r| States.actionable?(r.state) }
      end

      def record_by_id(setup_id)
        @lock.synchronize { find_record_unlocked(setup_id) }
      end

      def synchronize(&block)
        @lock.synchronize(&block)
      end

      def persist_record!(rec)
        @lock.synchronize do
          @journal.smc_setup_insert_or_update(
            setup_id: rec.setup_id,
            pair: rec.pair,
            state: rec.state,
            payload: rec.trade_setup.to_h,
            eval_state: rec.eval_state
          )
          sync_record_in_cache!(rec)
        end
      end

      def upsert_from_hash!(hash, reset_state: false)
        Validator.validate!(hash)
        ts = TradeSetup.from_hash(Validator.deep_symbolize(hash))
        @lock.synchronize do
          existing = @journal.smc_setup_get_row(ts.setup_id)
          unless existing
            count = @journal.smc_setup_count_for_pair(ts.pair)
            if count >= @max_per_pair
              raise Validator::ValidationError, "max_active_setups_per_pair reached for #{ts.pair}"
            end
          end

          state =
            if existing && !reset_state
              existing[:state].to_s
            else
              States::PENDING_SWEEP
            end
          ev =
            if existing
              parse_eval_hash(existing[:eval_state])
            else
              {}
            end
          @journal.smc_setup_insert_or_update(
            setup_id: ts.setup_id,
            pair: ts.pair,
            state: state,
            payload: ts.to_h,
            eval_state: ev
          )
        end
        reload!
        ts.setup_id
      end

      def update_state_and_eval!(setup_id, state:, eval_state: nil)
        @lock.synchronize do
          @journal.smc_setup_update_state_and_eval(setup_id: setup_id, state: state, eval_state: eval_state)
          @by_pair.each_value do |arr|
            rec = arr.find { |r| r.setup_id == setup_id }
            next unless rec

            rec.state = state.to_s
            rec.eval_state = eval_state if eval_state
            break
          end
        end
        reload! if States::TERMINAL.include?(state.to_s)
      end

      def merge_eval!(setup_id, eval_delta)
        @lock.synchronize do
          rec = find_record_unlocked(setup_id)
          return unless rec

          merged = rec.eval_state.merge(eval_delta.transform_keys(&:to_sym))
          @journal.smc_setup_update_state_and_eval(
            setup_id: setup_id,
            state: rec.state,
            eval_state: merged
          )
          rec.eval_state = merged
        end
      end

      private

      def sync_record_in_cache!(rec)
        @by_pair[rec.pair] ||= []
        arr = @by_pair[rec.pair]
        idx = arr.index { |r| r.setup_id == rec.setup_id }
        if idx
          arr[idx] = rec
        else
          arr << rec
        end
      end

      def find_record_unlocked(setup_id)
        @by_pair.each_value do |arr|
          found = arr.find { |r| r.setup_id == setup_id }
          return found if found
        end
        nil
      end

      def parse_eval_hash(raw)
        return {} if raw.nil?

        JSON.parse(raw.to_s, symbolize_names: true)
      rescue JSON::ParserError
        {}
      end

      def build_record(row)
        row = row.transform_keys(&:to_sym) if row.keys.first.is_a?(String)
        payload = JSON.parse(row[:payload].to_s, symbolize_names: true)
        Validator.validate!(payload)
        ts = TradeSetup.from_hash(payload)
        ev = parse_eval_hash(row[:eval_state])
        StoredRecord.new(
          setup_id: row[:setup_id].to_s,
          pair: row[:pair].to_s,
          state: row[:state].to_s,
          trade_setup: ts,
          eval_state: ev
        )
      rescue JSON::ParserError, Validator::ValidationError, KeyError
        nil
      end
    end
  end
end
