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
          sleeper: ->(seconds) { sleep(seconds) },
          after_apply: nil
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
          @after_apply = after_apply
          @mutex = Mutex.new
          @state = :idle
          @buffer = []
          @snapshot_last_update_id = nil
        end

        attr_reader :state

        # Optional hook invoked after each successfully applied depth event (live + replay).
        # Signature: +(binance_symbol, local_book, depth_event)+ — runs outside ResyncManager's buffer mutex.
        attr_writer :after_apply

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
          snap_u = Integer(snapshot.last_update_id)
          @snapshot_last_update_id = snap_u
          @book.replace!(
            last_update_id: snap_u,
            bids: snapshot.bids,
            asks: snapshot.asks
          )
          tail = aligned_tail_after_snapshot(buffered_events, snap_u)
          return self if tail.nil?

          tail.each { |event| step!(event) }
          self
        end

        # Pure: applies one diff — either the first after a REST snapshot (U<=L+1<=u)
        # while the book is still at L, or a normal continuation (pu == last u).
        # @raise [SequenceValidator::Desync] on misalignment or continuity gap.
        def step!(event)
          if awaiting_first_diff_after_snapshot?
            apply_first_event(event, @snapshot_last_update_id)
          else
            @validator.validate_continuity!(
              prev_u: event.prev_u,
              last_applied_u: @book.last_update_id
            )
            @book.apply_diff!(
              final_u: event.final_u,
              bids: event.bids,
              asks: event.asks,
              event_time: event.event_time
            )
          end
          notify_after_apply(event)
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
          return if stale_live_depth_event?(event)

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

        # Per Binance USDⓈ-M diff depth: drop buffered events with u < L (strict).
        # Then take the first event with U <= L+1 <= u; if buffered events exist but
        # none qualify, raise Desync so #start retries alignment.
        def aligned_tail_after_snapshot(events, snapshot_id)
          snap_u = Integer(snapshot_id)
          candidates = Array(events).reject { |event| event.final_u < snap_u }
          idx = candidates.index { |event| event_spans_snapshot_boundary?(event, snap_u) }
          if idx.nil?
            if candidates.any?
              raise SequenceValidator::Desync,
                    "no buffered event spans snapshot boundary for lastUpdateId=#{snap_u}"
            end

            return nil
          end

          candidates[idx..]
        end

        def event_spans_snapshot_boundary?(event, snapshot_id)
          boundary = Integer(snapshot_id) + 1
          event.first_u <= boundary && event.final_u >= boundary
        end

        def awaiting_first_diff_after_snapshot?
          @snapshot_last_update_id && @book.last_update_id == @snapshot_last_update_id
        end

        def stale_live_depth_event?(event)
          return false if event.prev_u.nil?
          return false unless @book.last_update_id
          return false if awaiting_first_diff_after_snapshot?

          event.prev_u < @book.last_update_id
        end

        def apply_first_event(event, snapshot_id)
          @validator.validate_initial!(
            first_u: event.first_u,
            final_u: event.final_u,
            snapshot_id: snapshot_id
          )
          @book.apply_diff!(
            final_u: event.final_u,
            bids: event.bids,
            asks: event.asks,
            event_time: event.event_time
          )
        end

        def notify_after_apply(event)
          cb = @after_apply
          return unless cb

          cb.call(@symbol, @book, event)
        end

        def log(level, message)
          @logger&.public_send(level, "[binance.resync] #{message}")
        end
      end
    end
  end
end
