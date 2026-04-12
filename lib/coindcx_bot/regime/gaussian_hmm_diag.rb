# frozen_string_literal: true

module CoindcxBot
  module Regime
    # Diagonal-covariance Gaussian HMM: Baum–Welch in log domain (moderate T), forward filtering for live inference.
    module GaussianHmmDiag
      Model = Struct.new(:n_states, :dim, :pi, :a, :means, :vars, keyword_init: true)

      module_function

      EPS = 1e-8

      def logsumexp(vec)
        m = vec.max
        m + Math.log(vec.sum { |z| Math.exp(z - m) })
      end

      def log_gaussian_diag(x, mean, var)
        d = mean.size
        sum = 0.0
        d.times do |j|
          v = [var[j], EPS].max
          diff = x[j] - mean[j]
          sum += -0.5 * (Math.log(2 * Math::PI * v) + (diff * diff) / v)
        end
        sum
      end

      def emission_loglik_matrix(obs, model)
        t_len = obs.size
        n = model.n_states
        Array.new(t_len) do |t|
          Array.new(n) do |j|
            log_gaussian_diag(obs[t], model.means[j], model.vars[j])
          end
        end
      end

      # Causal filtered posteriors p(z_t | o_0..t) — same math as forward message normalized.
      def forward_filtered_posteriors(obs, model)
        t_len = obs.size
        n = model.n_states
        log_b = emission_loglik_matrix(obs, model)
        log_pi = model.pi.map { |p| Math.log([p, EPS].max) }
        log_a = model.a.map { |row| row.map { |v| Math.log([v, EPS].max) } }

        posts = []
        log_alpha_prev = nil

        t_len.times do |t|
          log_alpha = Array.new(n, 0.0)
          n.times do |j|
            if t.zero?
              log_alpha[j] = log_pi[j] + log_b[t][j]
            else
              acc = []
              n.times do |i|
                acc << log_alpha_prev[i] + log_a[i][j] + log_b[t][j]
              end
              log_alpha[j] = logsumexp(acc)
            end
          end
          log_norm = logsumexp(log_alpha)
          row = log_alpha.map { |z| Math.exp(z - log_norm) }
          posts << row
          log_alpha_prev = log_alpha.map { |z| z - log_norm }
        end
        posts
      end

      def forward_filtered_last(obs, model)
        forward_filtered_posteriors(obs, model).last
      end

      def log_likelihood(obs, model)
        t_len = obs.size
        n = model.n_states
        log_b = emission_loglik_matrix(obs, model)
        log_pi = model.pi.map { |p| Math.log([p, EPS].max) }
        log_a = model.a.map { |row| row.map { |v| Math.log([v, EPS].max) } }
        log_alpha_prev = nil
        ll = 0.0

        t_len.times do |t|
          log_alpha = Array.new(n, 0.0)
          n.times do |j|
            if t.zero?
              log_alpha[j] = log_pi[j] + log_b[t][j]
            else
              acc = []
              n.times do |i|
                acc << log_alpha_prev[i] + log_a[i][j] + log_b[t][j]
              end
              log_alpha[j] = logsumexp(acc)
            end
          end
          log_norm = logsumexp(log_alpha)
          ll += log_norm
          log_alpha_prev = log_alpha.map { |z| z - log_norm }
        end
        ll
      end

      # Full forward–backward in log domain; returns gamma [T][n], xi [T-1][n][n], log_lik
      def forward_backward(obs, model)
        t_len = obs.size
        n = model.n_states
        log_b = emission_loglik_matrix(obs, model)
        log_pi = model.pi.map { |p| Math.log([p, EPS].max) }
        log_a = model.a.map { |row| row.map { |v| Math.log([v, EPS].max) } }

        log_alpha = Array.new(t_len) { Array.new(n, 0.0) }
        t_len.times do |t|
          n.times do |j|
            if t.zero?
              log_alpha[t][j] = log_pi[j] + log_b[t][j]
            else
              acc = []
              n.times do |i|
                acc << log_alpha[t - 1][i] + log_a[i][j] + log_b[t][j]
              end
              log_alpha[t][j] = logsumexp(acc)
            end
          end
        end

        log_lik = logsumexp(log_alpha[t_len - 1])

        log_beta = Array.new(t_len) { Array.new(n, 0.0) }
        n.times { |i| log_beta[t_len - 1][i] = 0.0 }
        (t_len - 2).downto(0) do |t|
          n.times do |i|
            acc = []
            n.times do |j|
              acc << log_a[i][j] + log_b[t + 1][j] + log_beta[t + 1][j]
            end
            log_beta[t][i] = logsumexp(acc)
          end
        end

        gamma = Array.new(t_len) { Array.new(n, 0.0) }
        t_len.times do |t|
          acc = []
          n.times do |i|
            acc << log_alpha[t][i] + log_beta[t][i]
          end
          ln = logsumexp(acc)
          n.times do |i|
            gamma[t][i] = Math.exp(log_alpha[t][i] + log_beta[t][i] - ln)
          end
        end

        xi = Array.new(t_len - 1) { Array.new(n) { Array.new(n, 0.0) } }
        (t_len - 1).times do |t|
          acc = []
          n.times do |i|
            n.times do |j|
              v = log_alpha[t][i] + log_a[i][j] + log_b[t + 1][j] + log_beta[t + 1][j]
              acc << v
            end
          end
          ln = logsumexp(acc)
          idx = 0
          n.times do |i|
            n.times do |j|
              xi[t][i][j] = Math.exp(acc[idx] - ln)
              idx += 1
            end
          end
        end

        [gamma, xi, log_lik]
      end

      def fit_em_step(obs, model)
        gamma, xi, ll = forward_backward(obs, model)
        t_len = obs.size
        n = model.n_states
        dim = obs.first.size

        n.times do |i|
          model.pi[i] = gamma[0][i]
        end
        ps = model.pi.sum
        model.pi.map! { |p| p / [ps, EPS].max }

        n.times do |i|
          denom = (t_len - 1).times.sum { |t| gamma[t][i] }
          denom = EPS if denom < EPS
          n.times do |j|
            num = (t_len - 1).times.sum { |t| xi[t][i][j] }
            model.a[i][j] = num / denom
          end
          rs = model.a[i].sum
          model.a[i].map! { |v| v / [rs, EPS].max }
        end

        n.times do |j|
          denom = t_len.times.sum { |t| gamma[t][j] }
          denom = EPS if denom < EPS
          dim.times do |d|
            model.means[j][d] = t_len.times.sum { |t| gamma[t][j] * obs[t][d] } / denom
          end
          dim.times do |d|
            var = t_len.times.sum { |t| gamma[t][j] * (obs[t][d] - model.means[j][d])**2 } / denom
            model.vars[j][d] = [var, EPS * 1e3].max
          end
        end

        ll
      end

      def random_init(n_states, dim, obs, rng)
        t_len = obs.size
        means = Array.new(n_states) { Array.new(dim, 0.0) }
        vars = Array.new(n_states) { Array.new(dim, 1.0) }
        n_states.times do |k|
          idx = rng.rand(t_len)
          dim.times do |d|
            means[k][d] = obs[idx][d]
            vars[k][d] = 1.0
          end
        end
        pi = Array.new(n_states) { 1.0 / n_states }
        a = Array.new(n_states) { Array.new(n_states) { 1.0 / n_states } }
        Model.new(n_states: n_states, dim: dim, pi: pi, a: a, means: means, vars: vars)
      end

      def fit_single(obs, n_states:, max_iter:, random:)
        n_states = [[n_states, 2].max, 12].min
        dim = obs.first.size
        model = random_init(n_states, dim, obs, random)
        last_ll = nil
        max_iter.times do
          ll = fit_em_step(obs, model)
          break if ll.nan? || ll.infinite?

          if last_ll && (ll - last_ll).abs < 0.1
            break
          end

          last_ll = ll
        end
        ll = log_likelihood(obs, model)
        [model, ll]
      end

      def bic(log_lik, n_states, dim, t_len)
        k = (n_states - 1) + n_states * (n_states - 1) + 2 * n_states * dim
        -2.0 * log_lik + k * Math.log([t_len, 1].max)
      end

      def select_and_fit(obs, n_candidates:, n_init:, max_iter:, random:)
        best = nil
        best_bic = Float::INFINITY
        n_candidates.each do |n_st|
          n_init.times do
            model, ll = fit_single(obs, n_states: n_st, max_iter: max_iter, random: random)
            next if ll.nan? || !ll.finite?

            b = bic(ll, n_st, obs.first.size, obs.size)
            if b < best_bic
              best_bic = b
              best = model
            end
          end
        end
        [best, best_bic]
      end

      def model_to_h(model)
        {
          'n_states' => model.n_states,
          'dim' => model.dim,
          'pi' => model.pi,
          'a' => model.a,
          'means' => model.means,
          'vars' => model.vars
        }
      end

      def model_from_h(h)
        Model.new(
          n_states: Integer(h['n_states']),
          dim: Integer(h['dim']),
          pi: h['pi'].map(&:to_f),
          a: h['a'].map { |row| row.map(&:to_f) },
          means: h['means'].map { |row| row.map(&:to_f) },
          vars: h['vars'].map { |row| row.map(&:to_f) }
        )
      end
    end
  end
end
