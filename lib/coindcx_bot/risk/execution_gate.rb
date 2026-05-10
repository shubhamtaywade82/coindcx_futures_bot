# frozen_string_literal: true

require_relative '../gateways/result'
require_relative '../exchanges/binance/symbol_map'

module CoindcxBot
  module Risk
    # Always allows exits; gates new entries using {DivergenceGuard} when enabled.
    class NoOpExecutionGate
      INSTANCE = new

      class << self
        def instance
          INSTANCE
        end
      end

      def gate?(action:, pair:, now_ms: nil)
        Gateways::Result.ok
      end
    end

    class ExecutionGate
      EVENT_BLOCKED = 'risk.execution.blocked'
      EVENT_UNBLOCKED = 'risk.execution.unblocked'

      ENTRY_ACTIONS = %i[open_long open_short].freeze

      def initialize(divergence_guards:, config:, logger:, bus:)
        @source = divergence_guards
        @config = config
        @logger = logger
        @bus = bus
        @cooldown_ms = [config.orderflow_divergence_gate_cooldown_ms, 1].max
        @mutex = Mutex.new
        @last_blocked_emit_wall_ms = {}
        @last_unblocked_emit_wall_ms = {}
        @pair_blocking = {}
      end

      def gate?(action:, pair:, now_ms: nil)
        return Gateways::Result.ok unless @config.orderflow_divergence_gate_enabled?

        act = action.to_sym
        return Gateways::Result.ok unless ENTRY_ACTIONS.include?(act)

        pair_s = pair.to_s
        return unmapped_pair_result(pair_s, act) unless binance_mapped?(pair_s)

        g = guard_for(pair_s)
        return Gateways::Result.ok if g.nil?

        res =
          if now_ms.nil?
            g.check(pair: pair_s)
          else
            g.check(pair: pair_s, now_ms: now_ms)
          end
        finalize_bus!(pair_s, act, res)
        res
      end

      private

      def binance_mapped?(pair_s)
        Exchanges::Binance::SymbolMap.to_binance(pair_s)
        true
      rescue Exchanges::Binance::SymbolMap::UnknownSymbol
        false
      end

      def unmapped_pair_result(pair_s, act)
        if @config.orderflow_divergence_gate_block_unmapped_pairs?
          res = Gateways::Result.err(
            :pair_not_binance_mapped,
            'pair has no Binance symbol map entry',
            { reason: :pair_not_binance_mapped, bps: nil, age_ms: nil }
          )
          finalize_bus!(pair_s, act, res)
          return res
        end

        Gateways::Result.ok
      end

      def guard_for(pair_s)
        if @source.respond_to?(:for)
          @source.for(pair: pair_s)
        else
          h = @source
          h[pair_s] || h[pair_s.to_sym]
        end
      end

      def wall_now_ms
        (Time.now.to_f * 1000).to_i
      end

      def finalize_bus!(pair_s, act, res)
        return unless @bus

        @mutex.synchronize do
          if res.err?
            emit_blocked_if_due!(pair_s, act, res)
            @pair_blocking[pair_s] = true
          else
            was = @pair_blocking.delete(pair_s)
            emit_unblocked_if_due!(pair_s, act) if was
          end
        end
      end

      def emit_blocked_if_due!(pair_s, act, res)
        vh = res.value.is_a?(Hash) ? res.value : {}
        reason = vh[:reason] || res.code
        key = "#{pair_s}:#{act}:#{reason}"
        now_ms = wall_now_ms
        last = @last_blocked_emit_wall_ms[key]
        return if last && (now_ms - last) < @cooldown_ms

        payload = {
          pair: pair_s,
          action: act,
          reason: reason,
          bps: vh[:bps],
          age_ms: vh[:age_ms]
        }
        @bus.publish(EVENT_BLOCKED, payload)
        @last_blocked_emit_wall_ms[key] = now_ms
      rescue StandardError => e
        @logger&.warn("[execution_gate] publish blocked: #{e.message}")
      end

      def emit_unblocked_if_due!(pair_s, act)
        key = "#{pair_s}:#{act}"
        now_ms = wall_now_ms
        last = @last_unblocked_emit_wall_ms[key]
        return if last && (now_ms - last) < @cooldown_ms

        @bus.publish(EVENT_UNBLOCKED, { pair: pair_s, action: act })
        @last_unblocked_emit_wall_ms[key] = now_ms
      rescue StandardError => e
        @logger&.warn("[execution_gate] publish unblocked: #{e.message}")
      end
    end
  end
end
