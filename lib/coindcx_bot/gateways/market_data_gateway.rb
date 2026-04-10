# frozen_string_literal: true

require 'bigdecimal'
require 'time'
require_relative 'ws_gateway'

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

      # REST quote for TUI display only (does not move strategy / `@ws_tick_at`).
      def fetch_instrument_display_quote(pair:)
        res = fetch_instrument(pair: pair)
        return res unless res.ok?

        quote = build_display_quote(res.value)
        return Result.fail(:validation, 'instrument payload missing price') unless quote

        Result.ok(quote)
      end

      # Single public snapshot: `ls` + `pc` per pair (same shape as currentPrices@futures/rt on the socket).
      # Prefer this for the TUI poller — `/derivatives/futures/data/instrument` often has no % change field.
      def fetch_futures_rt_quotes(pairs:)
        list = Array(pairs).map(&:to_s)
        guard_call do
          raw = @client.futures.market_data.current_prices
          helper = WsGateway.new(client: @client, logger: nil)
          ticks = helper.send(:ticks_from_current_prices_payload, raw, list)
          ticks.each_with_object({}) do |tick, acc|
            acc[tick.pair.to_s] = { price: tick.price, change_pct: tick.change_pct }
          end
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

      def build_display_quote(inst)
        h = instrument_flat_hash(inst)
        price_raw = extract_instrument_price(h)
        return nil if price_raw.nil?

        chg_raw = extract_instrument_change_pct(h)
        chg =
          if chg_raw.nil?
            nil
          else
            BigDecimal(chg_raw.to_s)
          end

        { price: BigDecimal(price_raw.to_s), change_pct: chg }
      rescue ArgumentError, TypeError
        nil
      end

      def instrument_flat_hash(inst)
        raw =
          case inst
          when Hash then inst
          else inst.respond_to?(:to_h) ? inst.to_h : {}
          end
        h = symbolize(raw)
        nested = h[:data]
        h = h.merge(symbolize(nested)) if nested.is_a?(Hash)
        h
      end

      def extract_instrument_price(h)
        keys = %i[
          last_traded_price ltp last_price mark_price index_price
          ls p price close last
        ]
        keys.each { |k| return h[k] if h.key?(k) && !h[k].nil? && h[k].to_s.strip != '' }
        nil
      end

      def extract_instrument_change_pct(h)
        keys = %i[change_24h change_pct pc percent_change_24h price_change_percent_24h]
        keys.each { |k| return h[k] if h.key?(k) && !h[k].nil? && h[k].to_s.strip != '' }
        nil
      end
    end
  end
end
