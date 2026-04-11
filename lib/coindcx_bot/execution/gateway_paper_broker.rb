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

      def process_tick(pair:, ltp:, high: nil, low: nil, candles: nil)
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
        row = find_open_position_row(rows, pair, position_id)
        unless row
          listed = rows.map { |r| position_row_instrument(r) }.reject(&:empty?).join(', ')
          @logger&.warn(
            "[gateway_paper] close #{pair}: no open position matched " \
            "(#{rows.size} in list#{listed.empty? ? '' : ": #{listed}"})"
          )
          return { ok: false, reason: :no_position }
        end

        pid = row[:id] || row['id']
        er = @account.exit_position({ id: pid.to_s })
        if er.failure?
          @logger&.warn("exit_position failed: #{er.message}")
          return { ok: false, reason: :exit_failed }
        end

        h = er.value
        h = h.transform_keys(&:to_sym) if h.is_a?(Hash)
        inner = h.is_a?(Hash) ? (h[:data] || h['data']) : nil
        inner = inner.transform_keys(&:to_sym) if inner.is_a?(Hash)
        src = inner.is_a?(Hash) ? inner : h
        {
          ok: true,
          realized_pnl_usdt: extract_realized_pnl_usdt(src),
          fill_price: extract_fill_price(src),
          position_id: pid
        }
      end

      private

      def extract_realized_pnl_usdt(h)
        return nil unless h.is_a?(Hash)

        raw = h[:realized_pnl_usdt] || h[:realized_pnl] || h[:pnl_usdt] ||
                h['realized_pnl_usdt'] || h['realized_pnl'] || h['pnl_usdt']
        return nil if raw.nil?

        BigDecimal(raw.to_s)
      rescue ArgumentError, TypeError
        nil
      end

      def extract_fill_price(h)
        return nil unless h.is_a?(Hash)

        raw = h[:fill_price] || h[:exit_price] || h['fill_price'] || h['exit_price']
        return nil if raw.nil?

        BigDecimal(raw.to_s)
      rescue ArgumentError, TypeError
        nil
      end

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
        list = extract_positions_list(value)
        Array(list).map { |h| h.is_a?(Hash) ? h.transform_keys(&:to_sym) : {} }
      end

      # CoinDCX envelopes: { "data" => { "positions" => [...] } }; paper exchange: { "positions" => [...] }.
      def extract_positions_list(raw)
        v = raw
        if v.is_a?(Hash) && (inner = v[:data] || v['data']).is_a?(Hash)
          v = inner
        end
        return v if v.is_a?(Array)
        return [] unless v.is_a?(Hash)

        arr = v[:positions] || v['positions'] || v[:open_positions] || v['open_positions']
        return arr if arr.is_a?(Array)

        v.values.grep(Array).first || []
      end

      def find_open_position_row(rows, pair, position_id)
        wanted = pair.to_s
        if position_id && !position_id.to_s.strip.empty?
          pid = position_id.to_s
          hit = rows.find { |r| (r[:id] || r['id']).to_s == pid }
          return hit if hit
        end

        rows.find { |r| pairs_match?(position_row_instrument(r), wanted) }
      end

      def position_row_instrument(r)
        (r[:pair] || r[:instrument] || r[:instrument_name] || r['pair'] || r['instrument'] || r['instrument_name']).to_s
      end

      def pairs_match?(api_pair, requested_pair)
        a = api_pair.to_s.strip
        b = requested_pair.to_s.strip
        return true if a == b

        futures_pair_key(a) == futures_pair_key(b)
      end

      def futures_pair_key(s)
        s.to_s.strip.upcase.sub(/\AB-/, '').tr('-', '_')
      end
    end
  end
end
