# frozen_string_literal: true

require_relative 'allocation'
require_relative 'hmm_engine'
require_relative 'features'
require_relative 'state_machine'

module CoindcxBot
  module Regime
    # Per-pair (or primary-pair) HMM lifecycle: load/train, forward updates, TUI-friendly hashes.
    class HmmRuntime
      def initialize(config:, logger: nil)
        @config = config
        @logger = logger
        @mutex = Mutex.new
        @engines = {}
        @state_by_pair = {}
        @history_argmax = Hash.new { |h, k| h[k] = [] }
        @last_candle_time_by_pair = {}
        @bars_since_train = Hash.new(0)
        @state_machines = Hash.new do |h, pair|
          h[pair] = StateMachine.new(confirmations: confirmations_cfg)
        end
      end

      # @return [Hash, nil] { state_id:, label:, posterior: } once the state machine confirms stability
      def stable_state_for(pair)
        @mutex.synchronize { @state_machines[pair].stable_state }
      end

      def refresh!(candles_by_pair)
        return unless @config.regime_hmm_enabled?

        targets = target_pairs(candles_by_pair)
        targets.each do |pair|
          candles = candles_by_pair[pair] || []
          refresh_pair!(pair, candles)
        end
      end

      def state_for(pair)
        @mutex.synchronize { @state_by_pair[pair] }
      end

      def tui_overlay(primary_pair = nil)
        pair = resolve_overlay_primary_pair(primary_pair)
        return {} if pair.nil?

        st = state_for(pair)
        return tui_overlay_waiting(pair) if st.nil?

        tier = Allocation.vol_tier(st.vol_rank, st.vol_rank_total)
        {
          active: true,
          enabled: true,
          regime_pair: pair,
          label: st.label.to_s[0, 14],
          probability_pct: st.probability.to_f * 100.0,
          stability_bars: st.consecutive_bars,
          flicker_display: st.flickering ? 'high' : 'low',
          confirmed: st.is_confirmed && !st.uncertainty,
          vol_rank_display: "#{st.vol_rank}/#{st.vol_rank_total}",
          transition_display: tier.to_s[0, 28],
          quant_display: format_quant(st),
          hmm_display: '—',
          status: st.uncertainty ? 'PIPE:UNC' : 'PIPE:HMM'
        }
      end

      def hmm_context_for_ai
        return {} unless @config.regime_hmm_enabled?

        if @config.regime_scope == 'global'
          p0 = @config.pairs.first
          st = state_for(p0)
          return {} if st.nil?

          slice = hmm_state_slice(st)
          return @config.pairs.to_h { |p| [p, slice.dup] }
        end

        out = {}
        @config.pairs.each do |pair|
          st = state_for(pair)
          next if st.nil?

          out[pair] = hmm_state_slice(st)
        end
        out
      end

      def engine_for(pair)
        @mutex.synchronize { @engines[pair] }
      end

      private

      # Prefer the TUI focus pair when it is a configured instrument — do not substitute another pair's
      # HMM state (that caused FOCUS: ETH while the strip showed SOL's regime).
      def resolve_overlay_primary_pair(primary_pair)
        p = primary_pair.to_s.strip
        configured = @config.pairs.map(&:to_s)
        return p if !p.empty? && configured.include?(p)

        configured.find { |pair| state_for(pair) }
      end

      def tui_overlay_waiting(pair)
        {
          active: false,
          enabled: true,
          regime_pair: pair,
          label: '—',
          probability_pct: nil,
          stability_bars: nil,
          flicker_display: 'n/a',
          confirmed: nil,
          vol_rank_display: 'n/a',
          transition_display: 'n/a',
          quant_display: '—',
          hmm_display: 'HMM: warming up (need bars)',
          status: 'PIPE:WAIT'
        }
      end

      def hmm_state_slice(st)
        {
          state_id: st.state_id,
          label: st.label,
          probability: st.probability.round(4),
          vol_rank: st.vol_rank,
          vol_rank_total: st.vol_rank_total,
          flickering: st.flickering,
          uncertainty: st.uncertainty,
          confirmed: st.is_confirmed
        }
      end

      def format_quant(st)
        "S#{st.state_id} p=#{(st.probability * 100).round(0)}%"
      end

      def target_pairs(candles_by_pair)
        if @config.regime_scope == 'global'
          [@config.pairs.first].compact
        else
          candles_by_pair.keys.select { |p| @config.pairs.include?(p.to_s) }.map(&:to_s)
        end
      end

      def refresh_pair!(pair, candles)
        return if candles.size < 40

        @mutex.synchronize do
          eng = (@engines[pair] ||= HmmEngine.new(config_hmm: @config.regime_hmm_hash, logger: @logger))
          last_t = candles.last&.time
          if last_t && @last_candle_time_by_pair[pair] == last_t
            # same closed bar; still re-run forward on full series (cheap)
          end
          @last_candle_time_by_pair[pair] = last_t

          path = @config.regime_hmm_persistence_path_for(pair)
          if eng.model.nil? && File.file?(path)
            eng.load_from_json!(path)
          end

          if eng.model.nil?
            ok = eng.train!(candles)
            eng.save_to_json(path) if ok && path
          elsif should_retrain?(pair)
            ok = eng.train!(candles)
            eng.save_to_json(path) if ok && path
            @bars_since_train[pair] = 0
          end

          indexed = Features.indexed_rows(candles, zscore_lookback: zscore_lookback_cfg)
          obs = indexed.map { |x| x[:row] }
          if obs.empty? || eng.model.nil?
            @state_by_pair[pair] = nil
          else
            posts = eng.filtered_posteriors(obs)
            post = posts.last
            candle_time = candles[indexed.last[:index]]&.time
            hist = @history_argmax[pair]
            st = eng.interpret_state(post, candle_time: candle_time, candle_index: indexed.last[:index], history_argmax: hist)
            if st
              sid = post.each_with_index.max_by { |pr, _i| pr }.last
              hist << sid
              hist.shift while hist.size > 50
              @state_by_pair[pair] = st
              @state_machines[pair].update(state_id: st.state_id, label: st.label, posterior: st.probability)
            end
          end

          @bars_since_train[pair] += 1 if last_t
        end
      end

      def should_retrain?(pair)
        every = @config.regime_hmm_hash.fetch(:retrain_every_bars, 0).to_i
        return false if every <= 0

        @bars_since_train[pair] >= every
      end

      def zscore_lookback_cfg
        @config.regime_hmm_hash.fetch(:zscore_lookback, 60).to_i
      end

      def confirmations_cfg
        @config.respond_to?(:regime_hmm_state_machine_confirmations) ? @config.regime_hmm_state_machine_confirmations : 2
      end
    end
  end
end
