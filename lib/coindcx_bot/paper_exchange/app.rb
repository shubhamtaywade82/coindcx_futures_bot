# frozen_string_literal: true

require 'json'
require 'bigdecimal'
require 'rack'

module CoindcxBot
  module PaperExchange
    class App
      def initialize(wallets:, orders:, positions:, tick_dispatcher:, logger: nil)
        @wallets = wallets
        @orders = orders
        @positions = positions
        @tick = tick_dispatcher
        @logger = logger
      end

      def call(env)
        method = env['REQUEST_METHOD']
        path = env['PATH_INFO'].to_s

        return json(200, { ok: true, service: 'coindcx-paper-exchange' }) if method == 'GET' && path == '/health'

        user_id = env['paper_exchange.user_id']
        body = env['paper_exchange.parsed_body'] || {}

        case [method, path]
        when ['GET', '/exchange/v1/derivatives/futures/wallets']
          json(200, @wallets.futures_details(user_id))
        when ['POST', '/exchange/v1/derivatives/futures/wallets/transfer']
          r = @wallets.futures_transfer(
            user_id,
            transfer_type: body['transfer_type'] || body[:transfer_type],
            amount: body['amount'] || body[:amount],
            currency_short_name: body['currency_short_name'] || body[:currency_short_name] || 'USDT'
          )
          json(200, r)
        when ['GET', '/exchange/v1/derivatives/futures/wallets/transactions']
          q = Rack::Utils.parse_nested_query(env['QUERY_STRING'].to_s)
          page = Integer(q['page'] || 1)
          size = Integer(q['size'] || 1000)
          json(200, { transactions: @wallets.futures_transactions(user_id, page: page, size: size) })
        when ['POST', '/exchange/v1/derivatives/futures/orders/create']
          order = body['order'] || body[:order] || body
          json(200, @orders.create(user_id, order))
        when ['POST', '/exchange/v1/derivatives/futures/orders/cancel']
          json(200, @orders.cancel(user_id, body))
        when ['POST', '/exchange/v1/derivatives/futures/orders']
          json(200, @orders.list(user_id, body))
        when ['POST', '/exchange/v1/derivatives/futures/positions']
          json(200, @positions.list(user_id, body))
        when ['POST', '/exchange/v1/derivatives/futures/positions/update_leverage']
          json(200, @positions.update_leverage(user_id, body))
        when ['POST', '/exchange/v1/derivatives/futures/positions/add_margin']
          json(200, @positions.add_margin(user_id, body))
        when ['POST', '/exchange/v1/derivatives/futures/positions/remove_margin']
          json(200, @positions.remove_margin(user_id, body))
        when ['POST', '/exchange/v1/derivatives/futures/positions/cancel_all_open_orders']
          json(200, @positions.cancel_all_open_orders(user_id, body))
        when ['POST', '/exchange/v1/derivatives/futures/positions/cancel_all_open_orders_for_position']
          json(200, @positions.cancel_all_open_orders_for_position(user_id, body))
        when ['POST', '/exchange/v1/derivatives/futures/positions/exit']
          json(200, @positions.exit_position(user_id, body))
        when ['POST', '/exchange/v1/derivatives/futures/positions/create_tpsl']
          json(200, @positions.create_tpsl(user_id, body))
        when ['POST', '/exchange/v1/derivatives/futures/positions/transactions']
          json(200, @positions.list_transactions(user_id, body))
        when ['GET', '/exchange/v1/derivatives/futures/positions/cross_margin_details']
          json(200, @positions.cross_margin_details(user_id))
        when ['POST', '/exchange/v1/derivatives/futures/positions/margin_type']
          json(200, @positions.update_margin_type(user_id, body))
        when ['POST', '/exchange/v1/paper/simulation/tick']
          pair = body['pair'] || body[:pair]
          ltp = body['ltp'] || body[:ltp]
          raise MarketRules::ValidationError, 'pair required' if pair.to_s.empty?
          raise MarketRules::ValidationError, 'ltp required' if ltp.nil? || ltp.to_s.empty?

          @tick.dispatch!(
            user_id,
            pair: pair,
            ltp: ltp,
            high: body['high'] || body[:high],
            low: body['low'] || body[:low]
          )
          json(200, { status: 'ok' })
        else
          json(404, { error: { message: 'not found', code: 'not_found', path: path } })
        end
      rescue MarketRules::ValidationError => e
        json(422, { error: { message: e.message, code: 'validation' } })
      rescue Ledger::InvariantError => e
        @logger&.error("[paper_exchange] #{e.class}: #{e.message}")
        json(500, { error: { message: 'ledger invariant', code: 'ledger' } })
      rescue ArgumentError => e
        json(400, { error: { message: e.message, code: 'bad_request' } })
      end

      private

      def json(status, obj)
        [status, { 'Content-Type' => 'application/json' }, [JSON.generate(obj)]]
      end
    end
  end
end
