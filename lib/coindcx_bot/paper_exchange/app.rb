# frozen_string_literal: true

require 'json'
require 'bigdecimal'
require 'rack'

require_relative '../synthetic_l1'

module CoindcxBot
  module PaperExchange
    class App
      def initialize(wallets:, orders:, positions:, tick_dispatcher:, store:, logger: nil)
        @wallets = wallets
        @orders = orders
        @positions = positions
        @tick = tick_dispatcher
        @store = store
        @logger = logger
      end

      def call(env)
        method = env['REQUEST_METHOD'].to_s.upcase
        path = env['PATH_INFO'].to_s
        norm = Auth.normalized_request_path(env)

        return json(200, { ok: true, service: 'coindcx-paper-exchange' }) if method == 'GET' && norm == '/health'

        return handle_public_market_get(env) if Auth.public_market_get?(env)

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
          result = @orders.create(user_id, order)
          log_order_create(order, result)
          json(200, result)
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
          @logger&.info("[paper_exchange] tick pair=#{pair} ltp=#{ltp}")
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

      def handle_public_market_get(env)
        path = Auth.normalized_request_path(env)
        case path
        when '/exchange/v1/derivatives/futures/data/instrument'
          status, body = public_instrument_response(env)
          json(status, body)
        when '/exchange/v1/derivatives/futures/data/active_instruments'
          json(200, public_active_instruments)
        when '/exchange/v1/derivatives/futures/data/trades'
          json(200, { trades: [] })
        when '/api/v1/derivatives/futures/data/stats'
          json(200, {})
        when '/api/v1/derivatives/futures/data/conversions'
          json(200, {})
        else
          json(404, { error: { message: 'not found', code: 'not_found', path: path } })
        end
      end

      def public_instrument_response(env)
        q = Rack::Utils.parse_nested_query(env['QUERY_STRING'].to_s)
        pair = (q['pair'] || q[:pair]).to_s
        raise MarketRules::ValidationError, 'pair required' if pair.empty?

        row = @store.db.get_first_row('SELECT ltp FROM pe_mark_prices WHERE pair = ?', [pair])
        ltp_s = row ? row['ltp'].to_s : ''
        ltp_bd =
          begin
            ltp_s.strip.empty? ? BigDecimal('0') : BigDecimal(ltp_s)
          rescue ArgumentError
            BigDecimal('0')
          end
        unless ltp_bd.positive?
          return [
            404,
            { error: { message: 'mark price not available yet', code: 'no_mark', pair: pair } }
          ]
        end

        bid_bd, ask_bd = CoindcxBot::SyntheticL1.quote_from_mid(ltp_bd)
        [
          200,
          {
            pair: pair,
            last_traded_price: ltp_s,
            ltp: ltp_s,
            mark_price: ltp_s,
            bid: bid_bd.to_s('F'),
            ask: ask_bd.to_s('F'),
            pc: '0',
            change_pct: '0'
          }
        ]
      end

      def public_active_instruments
        sql = <<~SQL
          SELECT DISTINCT pair FROM pe_mark_prices
          UNION
          SELECT DISTINCT pair FROM pe_orders
          ORDER BY 1
        SQL
        rows = @store.db.execute(sql)
        list = rows.map do |r|
          pair = r.is_a?(Hash) ? (r['pair'] || r[:pair]) : r[0]
          { pair: pair.to_s }
        end
        { pairs: list }
      end

      def log_order_create(order, result)
        return unless @logger

        o = order.is_a?(Hash) ? order : {}
        pair = o['pair'] || o[:pair]
        side = o['side'] || o[:side]
        otype = o['order_type'] || o[:order_type]
        oid = result.is_a?(Hash) ? (result['id'] || result[:id]) : nil
        @logger.info("[paper_exchange] order.create pair=#{pair} side=#{side} type=#{otype} id=#{oid}")
      end

      def json(status, obj)
        [status, { 'Content-Type' => 'application/json' }, [JSON.generate(obj)]]
      end
    end
  end
end
