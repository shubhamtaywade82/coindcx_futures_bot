# frozen_string_literal: true

require 'json'
require_relative 'features'
require_relative 'gaussian_hmm_diag'
require_relative 'types'

module CoindcxBot
  module Regime
    # High-level HMM: train (BIC), persist, forward-only inference + stability/flicker heuristics.
    class HmmEngine
      attr_reader :model, :regime_infos, :last_error

      def initialize(config_hmm:, logger: nil)
        @cfg = config_hmm.transform_keys(&:to_sym)
        @logger = logger
        @model = nil
        @regime_infos = []
        @last_error = nil
      end

      # @param candles [Array<Dto::Candle>] oldest first
      def train!(candles)
        @last_error = nil
        indexed = Features.indexed_rows(candles, zscore_lookback: zscore_lookback)
        if indexed.size < min_train_rows
          @last_error = "insufficient rows: #{indexed.size} < #{min_train_rows}"
          return false
        end

        obs = indexed.map { |x| x[:row] }
        rng = Random.new(seed)
        candidates = n_candidates
        n_starts = [[n_init, 1].max, 20].min
        max_it = [[em_iterations, 5].max, 200].min

        best, bic = GaussianHmmDiag.select_and_fit(
          obs,
          n_candidates: candidates,
          n_init: n_starts,
          max_iter: max_it,
          random: rng
        )
        if best.nil?
          @last_error = 'BIC selection failed'
          return false
        end

        @model = best
        @regime_infos = build_regime_infos(obs, indexed, best)
        @logger&.info("[hmm] trained n=#{@model.n_states} BIC=#{bic.round(2)} infos=#{@regime_infos.size}")
        true
      rescue StandardError => e
        @last_error = e.message
        @logger&.warn("[hmm] train: #{e.class} #{e.message}")
        false
      end

      def load_from_json!(path)
        @last_error = nil
        raw = JSON.parse(File.read(path))
        @model = GaussianHmmDiag.model_from_h(raw.fetch('model'))
        @regime_infos = (raw['regime_infos'] || []).map do |h|
          RegimeInfo.new(
            state_id: Integer(h['state_id']),
            label: h['label'].to_s,
            expected_return: h['expected_return'].to_f,
            expected_volatility: h['expected_volatility'].to_f
          )
        end
        true
      rescue StandardError => e
        @last_error = e.message
        false
      end

      def save_to_json(path)
        return false unless @model

        h = {
          'model' => GaussianHmmDiag.model_to_h(@model),
          'regime_infos' => @regime_infos.map do |ri|
            {
              'state_id' => ri.state_id,
              'label' => ri.label,
              'expected_return' => ri.expected_return,
              'expected_volatility' => ri.expected_volatility
            }
          end
        }
        File.write(path, JSON.pretty_generate(h))
        true
      end

      # Forward-only posterior for observation sequence (causal).
      def filtered_posteriors(obs_rows)
        return [] if @model.nil? || obs_rows.empty?

        GaussianHmmDiag.forward_filtered_posteriors(obs_rows, @model)
      end

      # @param candle_index [Integer] index into original candles for timestamp
      def interpret_state(posterior, candle_time:, candle_index:, history_argmax: [])
        return nil if @model.nil? || posterior.nil? || regime_infos.empty?

        n = posterior.size
        sid = posterior.each_with_index.max_by { |p, _i| p }.last
        prob = posterior[sid]
        info = @regime_infos.find { |r| r.state_id == sid } || @regime_infos[sid]

        sorted_by_vol = @regime_infos.sort_by(&:expected_volatility)
        vol_rank = sorted_by_vol.index(info) || 0
        vol_total = @regime_infos.size

        hist = (history_argmax + [sid]).last(flicker_window)
        flicker = flicker_count(hist) > flicker_threshold

        confirmed_streak = confirmation_streak(sid, history_argmax)
        is_confirmed = confirmed_streak >= stability_bars
        uncertainty = prob < min_confidence || flicker

        RegimeState.new(
          state_id: sid,
          label: info.label,
          probability: prob,
          probabilities: posterior.dup,
          timestamp: candle_time,
          is_confirmed: is_confirmed,
          consecutive_bars: confirmed_streak,
          flickering: flicker,
          uncertainty: uncertainty,
          vol_rank: vol_rank + 1,
          vol_rank_total: vol_total
        )
      end

      private

      def zscore_lookback
        @cfg.fetch(:zscore_lookback, 60).to_i
      end

      def min_train_rows
        @cfg.fetch(:min_train_bars, 80).to_i
      end

      def seed
        @cfg.fetch(:random_seed, 42).to_i
      end

      def n_candidates
        Array(@cfg.fetch(:n_candidates, [3, 4, 5])).map(&:to_i).uniq.sort
      end

      def n_init
        @cfg.fetch(:n_init, 3).to_i
      end

      def em_iterations
        @cfg.fetch(:em_iterations, 40).to_i
      end

      def stability_bars
        @cfg.fetch(:stability_bars, 3).to_i
      end

      def flicker_window
        @cfg.fetch(:flicker_window, 20).to_i
      end

      def flicker_threshold
        @cfg.fetch(:flicker_threshold, 4).to_i
      end

      def min_confidence
        Float(@cfg.fetch(:min_confidence, 0.55))
      end

      def confirmation_streak(sid, history_argmax)
        streak = 1
        history_argmax.reverse_each do |s|
          break if s != sid

          streak += 1
        end
        streak
      end

      def flicker_count(history)
        return 0 if history.size < 2

        history.each_cons(2).count { |a, b| a != b }
      end

      def build_regime_infos(obs, indexed, model)
        posts = GaussianHmmDiag.forward_filtered_posteriors(obs, model)
        n = model.n_states
        weight_sum = Array.new(n, 0.0)
        posts.each do |gamma|
          n.times do |j|
            weight_sum[j] += gamma[j]
          end
        end

        # Vol proxy: mean diagonal variance per state
        vols = n.times.map do |j|
          model.vars[j].sum / model.dim
        end
        # Return proxy: first feature is rough vol scale — weighted mean per state
        rets_mean = n.times.map do |j|
          sum = 0.0
          posts.each_with_index do |gamma, t|
            sum += gamma[j] * (obs[t][0] || 0.0)
          end
          w = [weight_sum[j], EPS].max
          sum / w
        end

        labels = %w[S0 S1 S2 S3 S4 S5 S6 S7 S8 S9 S10 S11]
        n.times.map do |j|
          RegimeInfo.new(
            state_id: j,
            label: labels[j] || "S#{j}",
            expected_return: rets_mean[j],
            expected_volatility: vols[j]
          )
        end
      end

      EPS = 1e-12
    end
  end
end
