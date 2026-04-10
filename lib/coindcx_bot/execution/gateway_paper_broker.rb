# frozen_string_literal: true

require 'bigdecimal'
require 'json'
require 'faraday'

module CoindcxBot
  module Execution
    # Paper mode that talks to the local CoinDCX-shaped paper exchange (REST + signed tick).
    class GatewayPaperBroker < LiveBroker
      def initialize(order_gateway:, account_gateway:, journal:, config:, exposure_guard:, logger: nil,
                     tick_base_url:, tick_path: '/exchange/v1/paper/simulation/tick',
                     api_key: nil, api_secret: nil)
        super(
          order_gateway: order_gateway,
          account_gateway: account_gateway,
          journal: journal,
          config: config,
          exposure_guard: exposure_guard,
          logger: logger
        )
        @tick_base_url = tick_base_url.to_s.chomp('/')
        @tick_path = tick_path.start_with?('/') ? tick_path : "/#{tick_path}"
        @api_key = (api_key || ENV.fetch('COINDCX_API_KEY')).to_s.strip
        @api_secret = (api_secret || ENV.fetch('COINDCX_API_SECRET')).to_s.strip
        @conn = Faraday.new(url: @tick_base_url) do |f|
          f.options.open_timeout = 5
          f.options.timeout = 15
        end
      end

      def paper?
        true
      end

      def process_tick(pair:, ltp:, high: nil, low: nil)
        return [] if @tick_base_url.empty? || ltp.nil?

        require 'coindcx'
        body = { pair: pair.to_s, ltp: ltp.to_s }
        body[:high] = high.to_s if high
        body[:low] = low.to_s if low

        signer = CoinDCX::Auth::Signer.new(api_key: @api_key, api_secret: @api_secret)
        normalized, headers = signer.authenticated_request(body)
        payload = JSON.generate(CoinDCX::Utils::Payload.stringify_keys(normalized))

        resp = @conn.post(@tick_path) do |req|
          req.headers['Content-Type'] = 'application/json'
          headers.each { |k, v| req.headers[k] = v }
          req.body = payload
        end

        unless resp.status.between?(200, 299)
          @logger&.warn("[gateway_paper] tick HTTP #{resp.status} #{resp.body}")
        end

        []
      rescue StandardError => e
        @logger&.warn("[gateway_paper] tick failed: #{e.class}: #{e.message}")
        []
      end

      def metrics
        {
          mode: 'gateway_paper_exchange'
        }
      end

      # Match journal + mark (same idea as {PaperBroker}) so the TUI header aligns with the execution matrix.
      def unrealized_pnl(ltp_map)
        @journal.open_positions.sum(BigDecimal('0')) do |pos|
          pair = (pos[:pair] || pos['pair']).to_s
          pair_ltp = ltp_map[pair] || ltp_map[pos[:pair].to_sym]
          next BigDecimal('0') unless pair_ltp

          mark_journal_position_unrealized(pos, BigDecimal(pair_ltp.to_s))
        end
      end

      def close_position(pair:, side:, quantity:, ltp:, position_id: nil)
        res = @account.list_positions
        if res.failure?
          @logger&.error("positions list failed: #{res.message}")
          return { ok: false, reason: :list_failed }
        end

        rows = normalize_rows(res.value)
        row = rows.find { |r| r[:pair].to_s == pair.to_s }
        return { ok: false, reason: :no_position } unless row

        pid = row[:id] || row['id']
        er = @account.exit_position({ id: pid.to_s })
        if er.failure?
          @logger&.warn("exit_position failed: #{er.message}")
          return { ok: false, reason: :exit_failed }
        end

        h = er.value
        h = h.transform_keys(&:to_sym) if h.is_a?(Hash)
        {
          ok: true,
          realized_pnl_usdt: h[:realized_pnl_usdt],
          fill_price: h[:fill_price] || h[:exit_price],
          position_id: pid
        }
      end

      private

      def mark_journal_position_unrealized(position, current_ltp)
        entry = BigDecimal((position[:entry_price] || position['entry_price']).to_s)
        qty = BigDecimal((position[:quantity] || position['quantity']).to_s)
        case (position[:side] || position['side']).to_s
        when 'long', 'buy'
          (current_ltp - entry) * qty
        when 'short', 'sell'
          (entry - current_ltp) * qty
        else
          BigDecimal('0')
        end
      rescue ArgumentError, TypeError
        BigDecimal('0')
      end

      def normalize_rows(value)
        list =
          case value
          when Array then value
          when Hash
            value[:positions] || value['positions'] || value[:data] || value.values.find { |v| v.is_a?(Array) } || []
          else
            []
          end
        Array(list).map { |h| h.is_a?(Hash) ? h.transform_keys(&:to_sym) : {} }
      end
    end
  end
end
