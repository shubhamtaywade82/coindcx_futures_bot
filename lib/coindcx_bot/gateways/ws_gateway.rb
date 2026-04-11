# frozen_string_literal: true

require 'bigdecimal'
require 'json'
require 'coindcx/ws/parsers/order_book_snapshot'

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

      # Futures LTP freshness:
      # - `new-trade` on @trades-futures carries "s" (instrument) and the correct per-instrument price.
      # - `price-change` on @prices-futures broadcasts the GLOBAL last-trade price to ALL subscribed
      #   channels with no instrument hint ("s" field absent). It must NOT be used as a price source
      #   — it would assign ETH's price to SOL and vice versa. It still keeps the WS liveness clock
      #   alive via ConnectionManager's touch_activity! (called in register_event_bridge before dispatch).
      def subscribe_futures_prices(instrument:, &block)
        price_channel = CoinDCX::WS::PublicChannels.futures_price_stats(instrument: instrument)
        @ws.subscribe_public(channel_name: price_channel, event_name: 'price-change') do |payload|
          h = normalize_payload_hash(payload)
          # Only forward when the payload explicitly names this instrument; global broadcasts have no
          # "s" field and carry a different instrument's price — skip them as price ticks.
          next unless instrument_hint_from_payload(h)

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

      # Futures L2 snapshot channel (depth 10, 20, or 50 per CoinDCX docs). Not a diff stream.
      def subscribe_futures_order_book(instrument:, depth: 10, &block)
        depth_i = Integer(depth)
        channel = CoinDCX::WS::PublicChannels.futures_order_book(instrument: instrument, depth: depth_i)
        event = CoinDCX::WS::PublicChannels::DEPTH_SNAPSHOT_EVENT
        @ws.subscribe_public(channel_name: channel, event_name: event) do |payload|
          raw = normalize_payload_hash(coerce_book_payload(payload))
          next if raw.empty?
          # Same Socket.IO fan-out as price-change: drop payloads whose instrument hint targets another market.
          next unless order_book_payload_applies_to_instrument?(instrument, raw)

          h = CoinDCX::WS::Parsers::OrderBookSnapshot.parse(raw)
          block.call(
            pair: instrument.to_s,
            bids: h[:bids] || [],
            asks: h[:asks] || []
          )
        end

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

      def coerce_book_payload(payload)
        case payload
        when String
          JSON.parse(payload)
        else
          payload
        end
      rescue JSON::ParserError
        {}
      end

      def order_book_payload_applies_to_instrument?(instrument, normalized_hash)
        hint = instrument_hint_from_payload(normalized_hash)
        return true if hint.nil? || hint.to_s.strip.empty?

        payload_instrument_matches?(instrument, normalized_hash)
      end

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

          bid, ask = extract_bid_ask_from_quote(raw)
          mk = extract_mark_from_quote(raw)

          Dto::Tick.new(
            pair: pair.to_s,
            price: BigDecimal(price_raw.to_s),
            change_pct: change_pct,
            received_at: Time.now,
            bid: bid,
            ask: ask,
            mark_price: mk
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

      def extract_bid_ask_from_quote(raw)
        return [nil, nil] unless raw.is_a?(Hash)

        h = raw.transform_keys { |k| k.to_sym }
        bid_raw = first_quote_scalar(h, %i[
          bid best_bid bid_price buy_price buy bp bb bid_px bidpx
        ])
        ask_raw = first_quote_scalar(h, %i[
          ask best_ask ask_price sell_price sell ap ba ask_px askpx
        ])
        [decimal_or_nil(bid_raw), decimal_or_nil(ask_raw)]
      end

      def first_quote_scalar(h, keys)
        keys.each do |k|
          next unless h.key?(k)

          v = h[k]
          next if v.nil? || v.to_s.strip.empty?

          return v
        end
        nil
      end

      def decimal_or_nil(v)
        return nil if v.nil?

        BigDecimal(v.to_s)
      rescue ArgumentError, TypeError
        nil
      end

      def extract_mark_from_quote(raw)
        return nil unless raw.is_a?(Hash)

        h = raw.transform_keys { |k| k.to_sym }
        mr = h[:mp] || h[:mark] || h[:mark_price]
        decimal_or_nil(mr)
      end

      def extract_price_and_change_from_quote(raw)
        case raw
        when Hash
          # currentPrices@futures/rt uses `ls` (last price) and `pc` (% change) per CoinDCX glossary.
          pr = raw[:ltp] || raw['ltp'] || raw[:ls] || raw['ls'] ||
               raw[:p] || raw['p'] || raw[:last_price] || raw['last_price'] ||
               raw[:price] || raw['price'] ||
               raw[:last_traded_price] || raw['last_traded_price'] ||
               raw[:mp] || raw['mp']
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

        bid, ask = extract_bid_ask_from_quote(h)
        mk = extract_mark_from_quote(h)

        Dto::Tick.new(
          pair: instrument,
          price: BigDecimal(price_raw.to_s),
          change_pct: change_pct,
          received_at: Time.now,
          bid: bid,
          ask: ask,
          mark_price: mk
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
