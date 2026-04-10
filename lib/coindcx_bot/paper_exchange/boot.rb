# frozen_string_literal: true

require 'bigdecimal'

module CoindcxBot
  module PaperExchange
    module Boot
      module_function

      def ensure_seed!(store, api_key:, api_secret:, seed_spot_usdt: '100000', seed_futures_usdt: '100000')
        db = store.db
        existing = db.get_first_row('SELECT user_id FROM pe_api_keys WHERE api_key = ?', [api_key])
        return existing['user_id'].to_i if existing

        db.execute('INSERT INTO pe_users (created_at) VALUES (?)', [store.now_iso])
        user_id = db.last_insert_row_id
        db.execute(
          'INSERT INTO pe_api_keys (user_id, api_key, api_secret) VALUES (?, ?, ?)',
          [user_id, api_key, api_secret]
        )

        ledger = Ledger.new(store)
        ledger.ensure_default_accounts!(user_id)
        spot = BigDecimal(seed_spot_usdt.to_s)
        fut = BigDecimal(seed_futures_usdt.to_s)

        ledger.post_batch!(
          user_id: user_id,
          external_ref: 'seed_initial',
          memo: 'bootstrap',
          lines: {
            Ledger::ACCOUNT_SPOT_AVAILABLE => spot,
            Ledger::ACCOUNT_FUTURES_AVAILABLE => fut,
            Ledger::ACCOUNT_EQUITY => -(spot + fut)
          }
        )

        user_id
      end
    end
  end
end
