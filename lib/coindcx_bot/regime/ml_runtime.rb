# frozen_string_literal: true

require_relative 'ml_model_bundle'
require_relative 'ml_predictor'

module CoindcxBot
  module Regime
    # Per-pair ML regime from the same z-scored HMM feature rows (causal); hysteresis on class switches.
    class MlRuntime
      def initialize(config:, logger: nil)
        @config = config
        @logger = logger
        @mutex = Mutex.new
        @bundle_by_pair = {}
        @predictor_by_pair = {}
        @state_by_pair = {}
        @last_confirmed_index = {}
        @debounce_buffer = Hash.new { |h, k| h[k] = [] }
        prime_bundles!
      end

      def refresh!(candles_by_pair)
        return unless @config.regime_ml_enabled?

        @config.pairs.each do |pair|
          candles = candles_by_pair[pair] || []
          refresh_pair!(pair, candles)
        end
      end

      def state_for(pair)
        @mutex.synchronize { @state_by_pair[pair] }
      end

      private

      def prime_bundles!
        return unless @config.regime_ml_enabled?

        @config.pairs.each { |pair| load_bundle!(pair) }
      end

      def load_bundle!(pair)
        return if @bundle_by_pair.key?(pair)

        path = @config.regime_ml_model_path_for(pair)
        unless File.file?(path)
          @logger&.warn("[regime.ml] missing model file: #{path}")
          mark_all_pairs_bundle!(pair, nil, nil)
          return
        end

        bundle = MlModelBundle.from_file(path)
        predictor = MlPredictor.new(bundle)
        mark_all_pairs_bundle!(pair, bundle, predictor)
      rescue StandardError => e
        @logger&.warn("[regime.ml] load #{path}: #{e.class} #{e.message}")
        mark_all_pairs_bundle!(pair, nil, nil)
      end

      def mark_all_pairs_bundle!(pair, bundle, predictor)
        if @config.regime_ml_scope_global?
          @config.pairs.each do |p|
            @bundle_by_pair[p] = bundle
            @predictor_by_pair[p] = predictor
          end
        else
          @bundle_by_pair[pair] = bundle
          @predictor_by_pair[pair] = predictor
        end
      end

      def refresh_pair!(pair, candles)
        bundle = @bundle_by_pair[pair]
        predictor = @predictor_by_pair[pair]
        if bundle.nil? || predictor.nil?
          @mutex.synchronize { @state_by_pair.delete(pair) }
          return
        end

        zlook = @config.regime_ml_zscore_lookback
        indexed = Features.indexed_rows(candles, zscore_lookback: zlook)
        if indexed.empty?
          @mutex.synchronize { @state_by_pair.delete(pair) }
          return
        end

        last = indexed.last
        row = last[:row]
        if row.size != bundle.feature_dimension
          @logger&.warn("[regime.ml] #{pair}: feature dim #{row.size} != bundle #{bundle.feature_dimension}")
          @mutex.synchronize { @state_by_pair.delete(pair) }
          return
        end

        raw = predictor.predict(row)

        @mutex.synchronize do
          confirmed_idx = debounced_class_index_locked(pair, raw)
          tier_sym = tier_for_class(bundle, bundle.classes[confirmed_idx])

          @state_by_pair[pair] = MlRegimeState.new(
            label: bundle.classes[confirmed_idx],
            class_index: confirmed_idx,
            probability: raw[:probabilities][confirmed_idx],
            probabilities: raw[:probabilities],
            tier: tier_sym,
            raw_label: raw[:label],
            raw_class_index: raw[:class_index],
            raw_max_probability: raw[:max_probability],
            candle_index: last[:index]
          )
        end
      end

      def tier_for_class(bundle, class_name)
        key = bundle.tier_by_class[class_name] || 'mid_vol'
        key.to_sym
      end

      # Caller must hold @mutex.
      def debounced_class_index_locked(pair, raw)
        raw_idx = raw[:class_index]
        confirm_bars = @config.regime_ml_confirm_bars
        immediate = raw[:max_probability] >= @config.regime_ml_immediate_probability

        prev = @last_confirmed_index[pair]
        if prev.nil?
          @last_confirmed_index[pair] = raw_idx
          return raw_idx
        end

        return raw_idx if raw_idx == prev

        buf = @debounce_buffer[pair]
        buf << raw_idx
        buf.shift while buf.size > confirm_bars

        confirmed_idx = if immediate || (buf.size >= confirm_bars && buf.all? { |x| x == raw_idx })
                          @debounce_buffer[pair].clear if raw_idx != prev
                          raw_idx
                        else
                          prev
                        end

        @last_confirmed_index[pair] = confirmed_idx
        confirmed_idx
      end
    end
  end
end
