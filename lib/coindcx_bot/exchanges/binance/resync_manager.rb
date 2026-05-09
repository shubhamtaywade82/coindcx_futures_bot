# frozen_string_literal: true

require_relative 'sequence_validator'

module CoindcxBot
  module Exchanges
    module Binance
      # Orchestrates the canonical Binance Futures depth reconstruction:
      #
      #   open WS → buffer events → fetch REST snapshot →
      #   drop pre-snapshot events → align first event → replay → live
      #
      # Pure logic (`replay_buffer!`, `step!`) is exposed for unit specs;
      # `start` wires WS + REST together for real runs and retries the
      # alignment up to `max_attempts` times when Desync is raised.
      class ResyncManager
        class GaveUp < StandardError
        end

        DEFAULT_MAX_ATTEMPTS = 5
        DEFAULT_BUFFER_WARMUP_SECONDS = 1.0
        DEFAULT_DEPTH_LIMIT = 1000
        DEFAULT_RETRY_BACKOFF_SECONDS = 0.5

        def initialize(
          symbol:,
          rest:,
          depth_ws:,
          book:,
          validator: SequenceValidator,
          logger: nil,
          max_attempts: DEFAULT_MAX_ATTEMPTS,
          depth_limit: DEFAULT_DEPTH_LIMIT,
          buffer_warmup_seconds: DEFAULT_BUFFER_WARMUP_SECONDS,
          retry_backoff_seconds: DEFAULT_RETRY_BACKOFF_SECONDS,
          sleeper: ->(seconds) { sleep(seconds) }
        )
          @symbol = symbol
          @rest = rest
          @ws = depth_ws
          @book = book
          @validator = validator
          @logger = logger
          @max_attempts = max_attempts
          @depth_limit = depth_limit
          @buffer_warmup_seconds = buffer_warmup_seconds
          @retry_backoff_seconds = retry_backoff_seconds
          @sleeper = sleeper
          @mutex = Mutex.new
          @state = :idle
          @buffer = []
        end

        attr_reader :state

        # Public: full lifecycle. Connects WS, buffers, fetches snapshot,
        # replays, transitions to live. Retries the alignment phase up to
        # @max_attempts times on Desync.
        def start
          attach_ws_callbacks
          enter_buffering_state
          @ws.connect
          run_sync_cycle_with_retry
          self
        end

        def stop
          @ws.disconnect
          @state = :idle
          self
        end

        # Pure: replays buffered events onto a fresh REST snapshot. Mutates @book.
        # @raise [SequenceValidator::Desync] when the first relevant event does not span the snapshot id.
        def replay_buffer!(buffered_events:, snapshot:)
          @book.replace!(
            last_update_id: snapshot.last_update_id,
            bids: snapshot.bids,
            asks: snapshot.asks
          )
          relevant = drop_pre_snapshot(buffered_events, snapshot.last_update_id)
          return self if relevant.empty?

          apply_first_event(relevant.first, snapshot.last_update_id)
          relevant.drop(1).each { |event| step!(event) }
          self
        end

        # Pure: validates continuity then applies a single live event.
        # @raise [SequenceValidator::Desync] when pu != book.last_update_id.
        def step!(event)
          @validator.validate_continuity!(
            prev_u: event.prev_u,
            last_applied_u: @book.last_update_id
          )
          @book.apply_diff!(final_u: event.final_u, bids: event.bids, asks: event.asks)
          self
        end

        private

        def attach_ws_callbacks
          @ws.on_event { |event| handle_ws_event(event) }
        end

        def handle_ws_event(event)
          @mutex.synchronize do
            @state == :live ? safe_step(event) : @buffer << event
          end
        end

        def safe_step(event)
          step!(event)
        rescue SequenceValidator::Desync => e
          log(:warn, "live continuity gap: #{e.message}")
          @state = :buffering
          @buffer.clear
          # The next sync cycle is triggered explicitly via #resync!.
        end

        def run_sync_cycle_with_retry
          attempts = 0
          begin
            attempts += 1
            do_sync_cycle
          rescue SequenceValidator::Desync => e
            log(:warn, "resync attempt #{attempts}/#{@max_attempts}: #{e.message}")
            raise GaveUp, "exceeded #{@max_attempts} alignment attempts" if attempts >= @max_attempts

            enter_buffering_state
            @sleeper.call(@retry_backoff_seconds)
            retry
          end
        end

        def do_sync_cycle
          @sleeper.call(@buffer_warmup_seconds)
          snapshot = @rest.depth(symbol: @symbol, limit: @depth_limit)
          @mutex.synchronize do
            replay_buffer!(buffered_events: @buffer, snapshot: snapshot)
            @buffer = []
            @state = :live
          end
        end

        def enter_buffering_state
          @mutex.synchronize do
            @state = :buffering
            @buffer = []
          end
        end

        def drop_pre_snapshot(events, snapshot_id)
          Array(events).reject { |event| event.final_u <= snapshot_id }
        end

        def apply_first_event(event, snapshot_id)
          @validator.validate_initial!(
            first_u: event.first_u,
            final_u: event.final_u,
            snapshot_id: snapshot_id
          )
          @book.apply_diff!(final_u: event.final_u, bids: event.bids, asks: event.asks)
        end

        def log(level, message)
          @logger&.public_send(level, "[binance.resync] #{message}")
        end
      end
    end
  end
end
