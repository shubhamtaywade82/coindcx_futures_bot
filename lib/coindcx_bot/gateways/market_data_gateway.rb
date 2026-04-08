# frozen_string_literal: true

require 'bigdecimal'
require 'time'

module CoindcxBot
  module Gateways
    class MarketDataGateway
      include Concerns::ErrorMapping

      def initialize(client:, margin_currency_short_name: 'USDT')
        @client = client
        @margin = margin_currency_short_name
      end

      def list_active_instruments(margin_currency_short_names: nil)
        names = margin_currency_short_names || [@margin]
        guard_call { @client.futures.market_data.list_active_instruments(margin_currency_short_names: names) }
      end

      def fetch_instrument(pair:)
        guard_call do
          @client.futures.market_data.fetch_instrument(pair: pair, margin_currency_short_name: @margin)
        end
      end

      def list_candlesticks(pair:, resolution:, from:, to:)
        guard_call do
          raw = @client.futures.market_data.list_candlesticks(
            pair: pair,
            from: from,
            to: to,
            resolution: resolution
          )
          normalize_candles(raw)
        end
      end

      private

      def normalize_candles(raw)
        rows =
          case raw
          when Array then raw
          when Hash
            raw[:data] || raw['data'] || raw[:candles] || raw['candles'] || raw.values.find { |v| v.is_a?(Array) } || []
          else
            []
          end
        Array(rows).map { |row| candle_from_row(row) }.compact
      end

      def candle_from_row(row)
        if row.is_a?(Array) && row.size >= 5
          t = extract_time_from_scalar(row[0])
          return nil unless t

          return Dto::Candle.new(
            time: t,
            open: decimal(row[1]),
            high: decimal(row[2]),
            low: decimal(row[3]),
            close: decimal(row[4]),
            volume: decimal(row[5] || 0)
          )
        end

        h = symbolize(row)
        time = extract_time(h)
        return nil unless time

        Dto::Candle.new(
          time: time,
          open: decimal(h[:open] || h[:o]),
          high: decimal(h[:high] || h[:h]),
          low: decimal(h[:low] || h[:l]),
          close: decimal(h[:close] || h[:c]),
          volume: decimal(h[:volume] || h[:v] || 0)
        )
      end

      def extract_time_from_scalar(t)
        return Time.at(Integer(t)) if t.is_a?(Numeric) || t.to_s.match?(/\A\d+\z/)

        Time.parse(t.to_s)
      rescue ArgumentError, TypeError
        nil
      end

      def extract_time(h)
        t = h[:time] || h[:t] || h[:timestamp]
        return Time.at(Integer(t)) if t.is_a?(Numeric) || t.to_s.match?(/\A\d+\z/)

        Time.parse(t.to_s)
      rescue ArgumentError, TypeError
        nil
      end

      def decimal(value)
        BigDecimal(value.to_s)
      end

      def symbolize(obj)
        case obj
        when Hash
          obj.each_with_object({}) { |(k, v), m| m[k.to_sym] = v }
        else
          {}
        end
      end
    end
  end
end
