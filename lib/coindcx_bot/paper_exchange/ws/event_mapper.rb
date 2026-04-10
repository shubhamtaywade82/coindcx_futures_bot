# frozen_string_literal: true

module CoindcxBot
  module PaperExchange
    module Ws
      # Maps internal simulator events to CoinDCX-style private websocket payloads (for a future EIO3 transport).
      module EventMapper
        module_function

        def balance_update(wallet_row)
          { event: 'balance_update', payload: wallet_row }
        end

        def order_update(order_hash)
          { event: 'order_update', payload: order_hash }
        end

        def position_update(position_hash)
          { event: 'position_update', payload: position_hash }
        end

        def transfer_completed(transfer_hash)
          { event: 'wallet_transfer', payload: transfer_hash }
        end
      end
    end
  end
end
