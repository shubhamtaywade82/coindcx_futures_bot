# frozen_string_literal: true

require 'bigdecimal'

module CoindcxBot
  module Orderflow
    # Bridges Binance +ResyncManager+ / +TradeWs+ into +Orderflow::Engine+ with throttled book snapshots.
    class BinanceAdapter
      THROTTLE_SECONDS = 0.1

      def initialize(
        engine:,
        book:,
        manager:,
        trade_ws:,
        coindcx_pair:,
        sweep_detector: nil,
        iceberg_detector: nil,
        logger: nil,
        binance_symbol: nil,
        book_ticker_ws: nil,
        divergence_monitor: nil
      )
        @engine = engine
        @book = book
        @manager = manager
        @trade_ws = trade_ws
        @pair = coindcx_pair.to_s
        @sweep = sweep_detector
        @iceberg = iceberg_detector
        @logger = logger
        @book_ticker_ws = book_ticker_ws
        @divergence_monitor = divergence_monitor
        @binance_symbol = binance_symbol || resolve_binance_symbol(@pair)
        @throttle_mutex = Mutex.new
        # Start in the distant past so the first depth tick always flushes.
        @last_push_mono = -Float::INFINITY
        wire_callbacks
      end

      def start
        @manager.start
        @trade_ws.connect
        @book_ticker_ws&.connect
        self
      end

      def stop
        @book_ticker_ws&.disconnect
        @trade_ws.disconnect
        @manager.stop
        self
      end

      private

      def wire_callbacks
        wire_book_ticker_divergence
        @manager.after_apply = method(:on_depth_applied).to_proc
        @trade_ws.on_trade { |t| @engine.on_trade(t) }
        @book.on_delta do |delta|
          @sweep&.feed_local_delta(pair: @pair, source: :binance, delta: delta)
          @iceberg&.feed_book_delta(pair: @pair, source: :binance, delta: delta)
        end
        @book.on_reset { @sweep&.reset!(@pair) }
      end

      def resolve_binance_symbol(pair)
        Exchanges::Binance::SymbolMap.to_binance(pair)
      rescue Exchanges::Binance::SymbolMap::UnknownSymbol
        nil
      end

      def wire_book_ticker_divergence
        return unless @book_ticker_ws && @divergence_monitor && @binance_symbol

        @book_ticker_ws.on_quote do |h|
          @divergence_monitor.on_binance_book_ticker(
            best_bid: h[:best_bid],
            best_ask: h[:best_ask],
            ts: h[:ts]
          )
        end
      end

      def on_depth_applied(_binance_symbol, book, event)
        ts_ms = Integer(event.event_time)
        mid = book.mid
        @sweep&.record_mid(pair: @pair, mid: mid, ts_ms: ts_ms) if mid

        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        bids_asks = nil
        emit_ts = ts_ms

        @throttle_mutex.synchronize do
          if now - @last_push_mono < THROTTLE_SECONDS
            return
          end

          @last_push_mono = now
          bids_asks = levels_for_engine(book)
          emit_ts = ts_ms
        end

        return unless bids_asks

        @engine.on_book_update(
          pair: @pair,
          bids: bids_asks[:bids],
          asks: bids_asks[:asks],
          source: :binance,
          ts: emit_ts
        )
      rescue StandardError => e
        @logger&.warn("[orderflow:binance_adapter] #{e.message}")
      end

      def levels_for_engine(book)
        bids = book.top_bids(1_000).map { |p, q| { price: p.to_s('F'), quantity: q.to_s('F') } }
        asks = book.top_asks(1_000).map { |p, q| { price: p.to_s('F'), quantity: q.to_s('F') } }
        { bids: bids, asks: asks }
      end
    end
  end
end
