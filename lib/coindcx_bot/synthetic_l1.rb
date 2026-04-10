# frozen_string_literal: true

require 'bigdecimal'

module CoindcxBot
  # Symmetric bid/ask around mid for display when the feed omits L1 (WS RT) or before paper mark exists.
  # Matches the paper exchange public instrument spread (1 bp each side).
  module SyntheticL1
    SPREAD_FRAC = BigDecimal('0.0001')

    def self.quote_from_mid(mid)
      m = BigDecimal(mid.to_s)
      return [nil, nil] unless m.positive?

      bid = m * (1 - SPREAD_FRAC)
      ask = m * (1 + SPREAD_FRAC)
      [bid, ask]
    rescue ArgumentError, TypeError
      [nil, nil]
    end

    def self.quote_from_mid_as_float(mid)
      bid, ask = quote_from_mid(mid)
      return [nil, nil] unless bid && ask

      [bid.to_f, ask.to_f]
    end
  end
end
