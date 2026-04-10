# frozen_string_literal: true

require 'bigdecimal'

module CoindcxBot
  module PaperExchange
    class WalletsService
      def initialize(store:, ledger:)
        @store = store
        @ledger = ledger
      end

      def futures_details(user_id, currency_short_name: 'USDT')
        snap = @ledger.futures_wallet_snapshot(user_id)
        return [] unless currency_short_name.to_s.casecmp('USDT').zero?

        [
          {
            currency_short_name: 'USDT',
            balance: snap[:balance].to_s('F'),
            locked_balance: snap[:locked_balance].to_s('F'),
            cross_order_margin: snap[:cross_order_margin].to_s('F'),
            cross_user_margin: snap[:cross_user_margin].to_s('F')
          }
        ]
      end

      def futures_transfer(user_id, transfer_type:, amount:, currency_short_name:)
        raise ArgumentError, 'USDT only' unless currency_short_name.to_s.casecmp('USDT').zero?

        amt = BigDecimal(amount.to_s)
        raise ArgumentError, 'amount must be positive' unless amt.positive?

        case transfer_type.to_s
        when 'deposit'
          spot_to_futures!(user_id, amt)
        when 'withdraw'
          futures_to_spot!(user_id, amt)
        else
          raise ArgumentError, "unknown transfer_type #{transfer_type}"
        end

        { status: 'ok', transfer_type: transfer_type.to_s, amount: amt.to_s('F') }
      end

      def futures_transactions(user_id, page: 1, size: 1000)
        rows = @store.db.execute(<<~SQL, [user_id])
          SELECT id, memo, created_at FROM pe_ledger_batches WHERE user_id = ? ORDER BY id DESC LIMIT 500
        SQL
        rows.map do |r|
          {
            id: r['id'],
            memo: r['memo'],
            created_at: r['created_at']
          }
        end
      end

      private

      def spot_to_futures!(user_id, amt)
        available = @ledger.spot_available(user_id)
        raise ArgumentError, 'insufficient spot balance' if available < amt

        @ledger.post_batch!(
          user_id: user_id,
          memo: 'spot_to_futures',
          lines: {
            Ledger::ACCOUNT_SPOT_AVAILABLE => -amt,
            Ledger::ACCOUNT_FUTURES_AVAILABLE => amt
          }
        )
      end

      def futures_to_spot!(user_id, amt)
        snap = @ledger.futures_wallet_snapshot(user_id)
        free = snap[:balance]
        raise ArgumentError, 'insufficient futures balance' if free < amt

        @ledger.post_batch!(
          user_id: user_id,
          memo: 'futures_to_spot',
          lines: {
            Ledger::ACCOUNT_FUTURES_AVAILABLE => -amt,
            Ledger::ACCOUNT_SPOT_AVAILABLE => amt
          }
        )
      end
    end
  end
end
