# frozen_string_literal: true

require 'bigdecimal'

module CoindcxBot
  module PaperExchange
    # Double-entry ledger: each batch must sum to zero (signed amounts per account).
    class Ledger
      class InvariantError < StandardError; end

      ACCOUNT_SPOT_AVAILABLE = 'spot:USDT:available'
      ACCOUNT_FUTURES_AVAILABLE = 'futures:USDT:available'
      ACCOUNT_FUTURES_LOCKED_ORDER = 'futures:USDT:locked_order'
      ACCOUNT_FUTURES_CROSS_ORDER_MARGIN = 'futures:USDT:cross_order_margin'
      ACCOUNT_FUTURES_CROSS_USER_MARGIN = 'futures:USDT:cross_user_margin'
      ACCOUNT_FEES = 'futures:USDT:fees'
      ACCOUNT_REALIZED_PNL = 'futures:USDT:realized_pnl'
      ACCOUNT_EQUITY = 'equity:USDT'

      def initialize(store)
        @db = store.db
        @store = store
      end

      def ensure_default_accounts!(user_id)
        default_codes(user_id).each do |code|
          @db.execute(
            'INSERT OR IGNORE INTO pe_ledger_accounts (user_id, code) VALUES (?, ?)',
            [user_id, code]
          )
        end
      end

      def account_id!(user_id, code)
        row = @db.get_first_row(
          'SELECT id FROM pe_ledger_accounts WHERE user_id = ? AND code = ?',
          [user_id, code]
        )
        raise InvariantError, "missing account #{code}" unless row

        row['id']
      end

      # lines: { code => BigDecimal signed amount } — sum must be ~0
      def post_batch!(user_id:, lines:, external_ref: nil, memo: nil)
        ensure_default_accounts!(user_id)
        sum = lines.values.sum(BigDecimal('0'))
        raise InvariantError, "ledger batch must balance (sum=#{sum})" unless sum.abs < BigDecimal('1e-12')

        @db.transaction do
          if external_ref
            existing = @db.get_first_row(
              'SELECT id FROM pe_ledger_batches WHERE user_id = ? AND external_ref = ?',
              [user_id, external_ref.to_s]
            )
            return existing['id'] if existing
          end

          @db.execute(
            'INSERT INTO pe_ledger_batches (user_id, external_ref, memo, created_at) VALUES (?, ?, ?, ?)',
            [user_id, external_ref&.to_s, memo, @store.now_iso]
          )
          batch_id = @db.last_insert_row_id

          lines.each do |code, amount|
            aid = account_id!(user_id, code)
            @db.execute(
              'INSERT INTO pe_ledger_lines (batch_id, account_id, amount_usdt) VALUES (?, ?, ?)',
              [batch_id, aid, amount.to_s('F')]
            )
          end

          batch_id
        end
      end

      def balance_for(user_id, code)
        ensure_default_accounts!(user_id)
        aid = account_id!(user_id, code)
        rows = @db.execute('SELECT amount_usdt FROM pe_ledger_lines WHERE account_id = ?', [aid])
        rows.sum(BigDecimal('0')) { |r| BigDecimal(r['amount_usdt'].to_s) }
      end

      def futures_wallet_snapshot(user_id)
        {
          balance: balance_for(user_id, ACCOUNT_FUTURES_AVAILABLE),
          locked_balance: balance_for(user_id, ACCOUNT_FUTURES_LOCKED_ORDER),
          cross_order_margin: balance_for(user_id, ACCOUNT_FUTURES_CROSS_ORDER_MARGIN),
          cross_user_margin: balance_for(user_id, ACCOUNT_FUTURES_CROSS_USER_MARGIN)
        }
      end

      def spot_available(user_id)
        balance_for(user_id, ACCOUNT_SPOT_AVAILABLE)
      end

      private

      def default_codes(_user_id)
        [
          ACCOUNT_SPOT_AVAILABLE,
          ACCOUNT_FUTURES_AVAILABLE,
          ACCOUNT_FUTURES_LOCKED_ORDER,
          ACCOUNT_FUTURES_CROSS_ORDER_MARGIN,
          ACCOUNT_FUTURES_CROSS_USER_MARGIN,
          ACCOUNT_FEES,
          ACCOUNT_REALIZED_PNL,
          ACCOUNT_EQUITY
        ]
      end
    end
  end
end
