# frozen_string_literal: true

require 'bigdecimal'
require 'json'

module CoindcxBot
  module Gateways
    class WsGateway
      include Concerns::ErrorMapping

      def initialize(client:, logger: nil)
        @client = client
        @ws = client.ws
        @logger = logger
        @logged_current_prices_miss = false
      end

      def connect
        guard_call do
          @ws.connect
          self
        end
      end

      def disconnect
        @ws.disconnect
      end

      # Futures LTP freshness: CoinDCX emits `price-change` on @prices-futures sparingly; the
      # @trades-futures + `new-trade` stream usually updates more often when the book is active.
      # Both feed the same tick pipeline so the TUI/engine last-tick clock stays realistic.
      def subscribe_futures_prices(instrument:, &block)
        price_channel = CoinDCX::WS::PublicChannels.futures_price_stats(instrument: instrument)
        @ws.subscribe_public(channel_name: price_channel, event_name: 'price-change') do |payload|
          tick = normalize_tick(instrument, payload)
          block.call(tick) if tick
        end

        trade_channel = CoinDCX::WS::PublicChannels.futures_new_trade(instrument: instrument)
        @ws.subscribe_public(channel_name: trade_channel, event_name: 'new-trade') do |payload|
          tick = normalize_tick(instrument, payload)
          block.call(tick) if tick
        end

        Result.ok(self)
      rescue CoinDCX::Errors::Error => e
        map_coin_dcx_error(e)
      end

      def subscribe_order_updates(&block)
        @ws.subscribe_private(event_name: CoinDCX::WS::PrivateChannels::ORDER_UPDATE_EVENT, &block)
        Result.ok(self)
      rescue CoinDCX::Errors::Error => e
        map_coin_dcx_error(e)
      end

      # Real-time snapshot of many futures instruments on one channel (CoinDCX smoke scripts use this).
      # Fills gaps when per-instrument @prices-futures / @trades-futures produce no parseable ticks.
      def subscribe_futures_current_prices_rt(pairs:, &block)
        channel = CoinDCX::WS::PublicChannels.current_prices_futures
        event = CoinDCX::WS::PublicChannels::CURRENT_PRICES_FUTURES_UPDATE_EVENT
        @ws.subscribe_public(channel_name: channel, event_name: event) do |payload|
          ticks = ticks_from_current_prices_payload(payload, pairs)
          log_current_prices_miss_once(payload) if ticks.empty?
          ticks.each { |tick| block.call(tick) }
        end

        Result.ok(self)
      rescue CoinDCX::Errors::Error => e
        map_coin_dcx_error(e)
      end

      private

      def ticks_from_current_prices_payload(payload, pairs)
        seeds = [payload]
        seeds.concat(payload) if payload.is_a?(Array)

        seeds.each do |chunk|
          h = normalize_payload_hash(chunk)
          next if h.empty?

          prices = extract_prices_table(h)
          prices = coalesce_prices_to_map(prices)
          next unless prices.is_a?(Hash) && !prices.empty?

          ticks = build_ticks_from_prices_map(prices, pairs)
          return ticks if ticks.any?
        end

        []
      end

      def log_current_prices_miss_once(payload)
        return if @logged_current_prices_miss
        return unless @logger

        h = normalize_payload_hash(payload)
        @logged_current_prices_miss = true
        @logger.warn(
          "[ws] currentPrices@futures: no ticks matched your pairs. Normalized top-level keys: #{h.keys.map(&:to_s).join(', ')}. " \
          'LTP still moves from REST candles — that does not clear STALE.'
        )
      end

      def build_ticks_from_prices_map(prices, pairs)
        Array(pairs).filter_map do |pair|
          raw = price_entry_for_instrument(prices, pair)
          next if raw.nil?

          price_raw, change_raw = extract_price_and_change_from_quote(raw)
          next if price_raw.nil?

          change_pct =
            if change_raw.nil?
              nil
            else
              BigDecimal(change_raw.to_s)
            end

          Dto::Tick.new(
            pair: pair.to_s,
            price: BigDecimal(price_raw.to_s),
            change_pct: change_pct,
            received_at: Time.now
          )
        end
      end

      # Walk nested hashes (CoinDCX wraps `prices` under varying keys / levels).
      def extract_prices_table(h)
        return nil unless h.is_a?(Hash)

        %w[prices price_list tickers markets futures_prices].each do |name|
          v = h[name.to_sym] || h[name]
          return v if v.is_a?(Hash) && !v.empty?
          return v if v.is_a?(Array) && !v.empty?
        end

        h.each_value do |v|
          next unless v.is_a?(Hash)

          inner = extract_prices_table(v)
          return inner if inner
        end
        nil
      end

      def coalesce_prices_to_map(prices)
        return prices if prices.is_a?(Hash)

        unless prices.is_a?(Array)
          return {}
        end

        out = {}
        prices.each do |row|
          next unless row.is_a?(Hash)

          rk = row[:pair] || row['pair'] || row[:symbol] || row['symbol'] ||
               row[:instrument] || row['instrument'] || row[:market] || row['market'] ||
               row[:s] || row['s']
          next if rk.nil? || rk.to_s.strip.empty?

          out[rk.to_s] = row
        end
        out
      end

      def price_entry_for_instrument(prices, pair)
        target = compact_instrument_code(pair)
        prices.each do |k, val|
          next if compact_instrument_code(k) != target

          return val
        end
        nil
      end

      def extract_price_and_change_from_quote(raw)
        case raw
        when Hash
          pr = raw[:ltp] || raw['ltp'] || raw[:p] || raw['p'] || raw[:last_price] || raw['last_price'] ||
               raw[:price] || raw['price'] || raw[:last_traded_price] || raw['last_traded_price']
          ch = raw[:pc] || raw['pc'] || raw[:change_pct] || raw['change_pct']
          [pr, ch]
        when Array
          extract_price_and_change_from_quote(raw.first)
        else
          [raw, nil]
        end
      end

      def normalize_tick(instrument, payload)
        h = normalize_payload_hash(payload)
        return nil if h.empty?

        unless payload_instrument_matches?(instrument, h)
          return nil
        end

        price_raw = h[:p] || h[:last_price] || h[:ltp] || h[:price] || h[:trade_price] || h[:rate] || h[:px]
        return nil if price_raw.nil?

        change_raw = h[:pc] || h[:change_pct]
        change_pct = change_raw.nil? ? nil : BigDecimal(change_raw.to_s)

        Dto::Tick.new(
          pair: instrument,
          price: BigDecimal(price_raw.to_s),
          change_pct: change_pct,
          received_at: Time.now
        )
      end

      def normalize_payload_hash(payload)
        h = coerce_payload_to_hash(payload)
        return {} if h.nil? || h.empty?

        merge_nested_quote_fields!(h)
        h
      end

      def coerce_payload_to_hash(payload)
        case payload
        when nil
          nil
        when String
          begin
            coerce_payload_to_hash(JSON.parse(payload))
          rescue JSON::ParserError
            {}
          end
        when Hash
          payload.transform_keys { |k| k.to_sym }
        when Array
          hashes = payload.select { |el| el.is_a?(Hash) }
          return {} if hashes.empty?

          hashes.map { |el| el.transform_keys { |k| k.to_sym } }.reduce { |acc, el| acc.merge(el) }
        else
          {}
        end
      end

      def merge_nested_quote_fields!(h)
        keys = %i[data payload message d result channelData channel_data body content info response quote]
        keys.each do |key|
          inner = h[key]
          if inner.is_a?(String) && !inner.strip.empty?
            inner = begin
              parsed = JSON.parse(inner)
              parsed if parsed.is_a?(Hash)
            rescue JSON::ParserError
              nil
            end
          end
          next unless inner.is_a?(Hash)

          h.merge!(inner.transform_keys { |k| k.to_sym })
        end
        h
      end

      # CoinDCX broadcasts one Socket.IO event to all listeners; filter using payload instrument hints.
      def payload_instrument_matches?(instrument, h)
        hint = instrument_hint_from_payload(h)
        return true if hint.nil? || hint.to_s.strip.empty?

        compact_instrument_code(hint) == compact_instrument_code(instrument)
      end

      def instrument_hint_from_payload(h)
        raw = h[:s] || h[:S] || h[:pair] || h[:market] || h[:instrument] || h[:symbol] || h[:trading_pair]
        raw = raw.first if raw.is_a?(Array) && raw.first
        raw
      end

      # Normalize CoinDCX instrument aliases (B-SOL_USDT, SOLUSDT, SOL-USDT, etc.) to one comparable token.
      # Use a single-letter market prefix only (e.g. B-); `[A-Z]+-` would strip "SOL-" from "SOL-USDT".
      def compact_instrument_code(code)
        s = code.to_s.strip.upcase
        s = s.sub(/\A[A-Z]-/, '')
        s.gsub(/[_-]/, '')
      end
    end
  end
end
