# frozen_string_literal: true

require_relative '../exchanges/binance/symbol_map'

module CoindcxBot
  module MarketData
    # Chooses which venue supplies orderflow-style intelligence for a CoinDCX pair.
    # YAML +{orderflow.binance.symbols}+ overrides extend the built-in +SymbolMap+ table.
    class SourceRouter
      def initialize(config)
        @config = config
      end

      # @return [:binance, :coindcx]
      def intelligence_source_for_pair(pair)
        binance_symbol_for_coindcx_pair(pair) ? :binance : :coindcx
      end

      # @return [String, nil] e.g. +"SOLUSDT"+
      def binance_symbol_for_coindcx_pair(pair)
        p = pair.to_s
        from_yaml = inverted_binance_symbols[p]
        return from_yaml if from_yaml

        CoindcxBot::Exchanges::Binance::SymbolMap::COINDCX_TO_BINANCE.fetch(p)
      rescue CoindcxBot::Exchanges::Binance::SymbolMap::UnknownSymbol, KeyError
        nil
      end

      private

      def inverted_binance_symbols
        h = orderflow_binance_section[:symbols]
        return {} unless h.is_a?(Hash)

        h.each_with_object({}) do |(bin, cdcx), acc|
          acc[cdcx.to_s] = bin.to_s.upcase
        end
      end

      def orderflow_binance_section
        sec = @config.respond_to?(:orderflow_section) ? @config.orderflow_section : {}
        b = sec[:binance]
        b.is_a?(Hash) ? b : {}
      end
    end
  end
end
