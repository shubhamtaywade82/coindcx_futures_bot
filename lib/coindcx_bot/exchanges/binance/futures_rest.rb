# frozen_string_literal: true

require 'bigdecimal'
require 'json'
require 'net/http'
require 'uri'

module CoindcxBot
  module Exchanges
    module Binance
      # Thin REST client for Binance USDⓈ-M Futures market data.
      # Phase 1 only needs the depth snapshot used as the anchor for the
      # incremental WS reconstruction.
      class FuturesRest
        DEFAULT_HOST = 'https://fapi.binance.com'
        DEFAULT_LIMIT = 1000
        DEFAULT_OPEN_TIMEOUT = 5
        DEFAULT_READ_TIMEOUT = 10

        Snapshot = Struct.new(:last_update_id, :bids, :asks, keyword_init: true) do
          alias_method :final_u, :last_update_id
        end

        class Error < StandardError
        end

        def initialize(base_url: DEFAULT_HOST, open_timeout: DEFAULT_OPEN_TIMEOUT, read_timeout: DEFAULT_READ_TIMEOUT)
          @base_url = base_url
          @open_timeout = open_timeout
          @read_timeout = read_timeout
        end

        # GET /fapi/v1/depth — returns Snapshot with BigDecimal-typed levels.
        def depth(symbol:, limit: DEFAULT_LIMIT)
          body = get_json(depth_uri(symbol: symbol, limit: limit))
          Snapshot.new(
            last_update_id: Integer(body.fetch('lastUpdateId')),
            bids: parse_levels(body['bids']),
            asks: parse_levels(body['asks'])
          )
        end

        private

        def depth_uri(symbol:, limit:)
          URI.parse("#{@base_url}/fapi/v1/depth?symbol=#{symbol.to_s.upcase}&limit=#{Integer(limit)}")
        end

        def get_json(uri)
          response = http_for(uri).request(Net::HTTP::Get.new(uri.request_uri))
          raise Error, "depth request failed: #{response.code} #{response.body}" unless response.is_a?(Net::HTTPSuccess)

          JSON.parse(response.body)
        rescue JSON::ParserError => e
          raise Error, "invalid JSON from #{uri}: #{e.message}"
        end

        def http_for(uri)
          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = uri.scheme == 'https'
          http.open_timeout = @open_timeout
          http.read_timeout = @read_timeout
          http
        end

        def parse_levels(rows)
          Array(rows).map do |(price, qty)|
            [BigDecimal(price.to_s), BigDecimal(qty.to_s)]
          end
        end
      end
    end
  end
end
