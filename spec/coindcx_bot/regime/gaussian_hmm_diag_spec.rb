# frozen_string_literal: true

require 'spec_helper'
require_relative '../../../lib/coindcx_bot/regime/gaussian_hmm_diag'

RSpec.describe CoindcxBot::Regime::GaussianHmmDiag do
  def random_obs(t, d, rng)
    Array.new(t) { Array.new(d) { rng.rand * 2 - 1 } }
  end

  describe 'forward_filtered_posteriors' do
    it 'matches filtered posterior at t when future observations are appended (fixed model)' do
      rng = Random.new(7)
      obs_full = random_obs(120, 4, rng)
      model, ll = described_class.fit_single(obs_full, n_states: 4, max_iter: 25, random: Random.new(1))
      skip 'EM did not converge' if model.nil? || ll.nan? || !ll.finite?

      short = obs_full[0, 60]
      long = obs_full[0, 90]
      ps_short = described_class.forward_filtered_posteriors(short, model)
      ps_long = described_class.forward_filtered_posteriors(long, model)
      t = 49
      expect(ps_short[t].size).to eq(model.n_states)
      ps_short[t].each_with_index do |a, i|
        expect(a).to be_within(1e-9).of(ps_long[t][i])
      end
    end
  end
end
