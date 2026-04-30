# frozen_string_literal: true

module CoindcxBot
  module Regime
    # Softmax multinomial logistic on a fixed feature vector (same order as bundle.feature_order).
    class MlPredictor
      def initialize(bundle)
        @bundle = bundle
        @k = bundle.class_count
      end

      # @param vector [Array<Float>] length == bundle.feature_dimension
      # @return [Hash] :class_index, :label, :probabilities, :max_probability, :second_probability
      def predict(vector)
        x = vector.map(&:to_f)
        d = @bundle.feature_dimension
        raise ArgumentError, "vector dim #{x.size} != #{d}" unless x.size == d

        logits = (0...@k).map do |i|
          @bundle.biases[i] + @bundle.weights[i].each_with_index.sum { |w, j| w * x[j] }
        end
        probs = softmax(logits)
        top = probs.each_with_index.max(2)
        p1, i1 = top[0]
        p2, = top[1]

        {
          class_index: i1,
          label: @bundle.classes[i1],
          probabilities: probs,
          max_probability: p1,
          second_probability: p2
        }
      end

      private

      def softmax(logits)
        m = logits.max
        exps = logits.map { |z| Math.exp(z - m) }
        s = exps.sum
        raise ZeroDivisionError, 'softmax underflow' if s < 1e-300

        exps.map { |e| e / s }
      end
    end
  end
end
