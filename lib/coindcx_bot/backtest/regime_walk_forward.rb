# frozen_string_literal: true

require_relative '../regime/features'
require_relative '../regime/gaussian_hmm_diag'
require_relative '../dto/candle'

module CoindcxBot
  module Backtest
    # Deterministic walk-forward: train HMM on a prefix of features, score OOS tail (no Ollama, no orders).
    class RegimeWalkForward
      Result = Struct.new(:train_bars, :oos_bars, :n_states, :bic, :log_lik, keyword_init: true)

      def self.run(candles:, train_fraction: 0.65, hmm_config: {}, rng: Random.new(42))
        new(candles: candles, train_fraction: train_fraction, hmm_config: hmm_config, rng: rng).run
      end

      def initialize(candles:, train_fraction:, hmm_config:, rng:)
        @candles = candles
        @train_fraction = train_fraction
        @hmm = hmm_config.transform_keys(&:to_sym)
        @rng = rng
      end

      def run
        indexed = Regime::Features.indexed_rows(
          @candles,
          zscore_lookback: @hmm.fetch(:zscore_lookback, 40).to_i
        )
        return Result.new(train_bars: 0, oos_bars: 0, n_states: 0, bic: 0.0, log_lik: 0.0) if indexed.size < 50

        obs = indexed.map { |x| x[:row] }
        split = (obs.size * @train_fraction).floor
        split = [[split, 30].max, obs.size - 10].min
        train_obs = obs[0, split]
        oos_obs = obs[split..] || []

        candidates = Array(@hmm.fetch(:n_candidates, [3, 4])).map(&:to_i)
        n_init = [[@hmm.fetch(:n_init, 2).to_i, 1].max, 5].min
        max_iter = [[@hmm.fetch(:em_iterations, 25).to_i, 5].max, 80].min

        model, bic = Regime::GaussianHmmDiag.select_and_fit(
          train_obs,
          n_candidates: candidates,
          n_init: n_init,
          max_iter: max_iter,
          random: @rng
        )
        return Result.new(train_bars: train_obs.size, oos_bars: oos_obs.size, n_states: 0, bic: bic, log_lik: 0.0) unless model

        ll = Regime::GaussianHmmDiag.log_likelihood(oos_obs, model) if oos_obs.any?
        ll ||= 0.0

        Result.new(
          train_bars: train_obs.size,
          oos_bars: oos_obs.size,
          n_states: model.n_states,
          bic: bic,
          log_lik: ll
        )
      end
    end
  end
end
