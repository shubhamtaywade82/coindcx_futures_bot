# frozen_string_literal: true

module CoindcxBot
  module Exchanges
    module Binance
      # Single source of truth for Binance ↔ CoinDCX symbol equivalence.
      # Phase 1 ships BTCUSDT only; extend the table as more pairs come online.
      module SymbolMap
        BINANCE_TO_COINDCX = {
          'BTCUSDT' => 'B-BTC_USDT',
        }.freeze

        COINDCX_TO_BINANCE = BINANCE_TO_COINDCX.invert.freeze

        module_function

        def to_coindcx(binance_symbol)
          BINANCE_TO_COINDCX.fetch(binance_symbol.to_s.upcase) do
            raise UnknownSymbol, "no CoinDCX mapping for #{binance_symbol.inspect}"
          end
        end

        def to_binance(coindcx_pair)
          COINDCX_TO_BINANCE.fetch(coindcx_pair.to_s) do
            raise UnknownSymbol, "no Binance mapping for #{coindcx_pair.inspect}"
          end
        end

        def supported_binance_symbols
          BINANCE_TO_COINDCX.keys
        end

        class UnknownSymbol < StandardError
        end
      end
    end
  end
end
