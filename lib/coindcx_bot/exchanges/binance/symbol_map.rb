# frozen_string_literal: true

module CoindcxBot
  module Exchanges
    module Binance
      # Single source of truth for Binance ↔ CoinDCX symbol equivalence.
      # Only pairs with a documented B-*_USDT-style CoinDCX code are listed.
      module SymbolMap
        BINANCE_TO_COINDCX = {
          'ADAUSDT' => 'B-ADA_USDT',
          'APTUSDT' => 'B-APT_USDT',
          'ARBUSDT' => 'B-ARB_USDT',
          'ATOMUSDT' => 'B-ATOM_USDT',
          'AVAXUSDT' => 'B-AVAX_USDT',
          'BNBUSDT' => 'B-BNB_USDT',
          'BTCUSDT' => 'B-BTC_USDT',
          'DOGEUSDT' => 'B-DOGE_USDT',
          'DOTUSDT' => 'B-DOT_USDT',
          'ETHUSDT' => 'B-ETH_USDT',
          'FILUSDT' => 'B-FIL_USDT',
          'INJUSDT' => 'B-INJ_USDT',
          'LINKUSDT' => 'B-LINK_USDT',
          'LTCUSDT' => 'B-LTC_USDT',
          'MATICUSDT' => 'B-MATIC_USDT',
          'NEARUSDT' => 'B-NEAR_USDT',
          'OPUSDT' => 'B-OP_USDT',
          'SOLUSDT' => 'B-SOL_USDT',
          'TRXUSDT' => 'B-TRX_USDT',
          'XRPUSDT' => 'B-XRP_USDT',
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
