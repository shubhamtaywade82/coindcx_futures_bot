# frozen_string_literal: true

require 'json'

module CoindcxBot
  module Exchanges
    module Binance
      # Multiplexed +@bookTicker+ stream; same lifecycle as +BookTickerWs+.
      class MultiplexedBookTickerWs
        DEFAULT_HOST = BookTickerWs::DEFAULT_HOST

        # rubocop:disable Metrics/AbcSize
        def initialize(symbol_map:, base_ws: DEFAULT_HOST, max_symbols_per_socket: 25, logger: nil, transport: nil)
          @logger = logger
          @transport_template = transport
          list = symbol_map.to_h.transform_keys { |k| k.to_s.strip.upcase }.transform_values { |v| v.to_s.strip }
          @symbol_to_pair = list.reject { |ks, vs| ks.empty? || vs.empty? }
          raise ArgumentError, 'multiplexed bookTicker requires a non-empty symbol_map' if @symbol_to_pair.empty?

          m = Integer(max_symbols_per_socket.to_s)
          m = 25 if m < 1

          chunks = @symbol_to_pair.keys.each_slice(m).to_a
          @partitions = chunks.map do |chunk_syms|
            chunk_map = chunk_syms.to_h { |s| [s, @symbol_to_pair[s]] }
            BookPartition.new(chunk_map, base_ws: base_ws.to_s.strip.chomp('/'), logger: @logger, transport: @transport_template)
          end
          @symbol_to_partition = {}
          @symbol_to_pair.each_key do |sym|
            @symbol_to_partition[sym] = @partitions.find { |p| p.symbols.include?(sym) }
          end
          @feeds = @symbol_to_pair.keys.to_h do |sym|
            [sym, BookStreamFeed.new(partition: @symbol_to_partition[sym], symbol_upper: sym, coindcx_pair: @symbol_to_pair[sym])]
          end
        end
        # rubocop:enable Metrics/AbcSize

        def stream_for(binance_symbol_upper)
          @feeds.fetch(binance_symbol_upper.to_s.upcase)
        end

        def connect
          @partitions.each(&:ensure_connected!)
          self
        end

        def disconnect
          @partitions.each(&:force_disconnect!)
          self
        end

        def partition_urls
          @partitions.map(&:url)
        end

        class BookPartition
          def initialize(symbol_to_pair, base_ws:, logger:, transport:)
            @symbol_to_pair = symbol_to_pair
            @symbols = symbol_to_pair.keys
            @logger = logger
            @transport_template = transport
            @listeners = {}
            @mutex = Mutex.new
            @open_gate = Mutex.new
            @transport = nil
            @connected = false
            stream_path = @symbols.map { |s| "#{s.downcase}@bookTicker" }.join('/')
            @url = "#{base_ws}/stream?streams=#{stream_path}"
          end

          attr_reader :url, :symbols

          def attach(feed)
            sym = feed.symbol_upper
            raise ArgumentError, "#{sym} not in bookTicker partition" unless @symbols.include?(sym)

            @open_gate.synchronize do
              @mutex.synchronize { @listeners[sym] = feed }

              if @transport.nil?
                start_transport_core!
              else
                feed.fire_on_open_async
              end
            end
          end

          def detach(feed)
            sym = feed.symbol_upper
            @open_gate.synchronize do
              @mutex.synchronize { @listeners.delete(sym) }
              empty = @mutex.synchronize { @listeners.empty? }
              close_transport_unlocked! if empty
            end
          end

          def ensure_connected!
            @open_gate.synchronize { start_transport_core! if @transport.nil? }
          end

          def force_disconnect!
            @open_gate.synchronize { close_transport_unlocked! }
          end

          private

          def start_transport_core!
            return if @transport

            t = @transport_template || default_transport
            @transport = t
            t.connect(
              url: @url,
              on_message: ->(raw) { dispatch_raw(raw) },
              on_open: -> { mark_connected_and_fire_opens! },
              on_close: ->(info) { fire_all_on_close(info) },
              on_error: ->(err) { fire_all_on_error(err) }
            )
          end

          def mark_connected_and_fire_opens!
            feeds = @mutex.synchronize do
              @connected = true
              @listeners.values.dup
            end
            feeds.each(&:fire_on_open_async)
          end

          def close_transport_unlocked!
            @transport&.close
            @transport = nil
            @mutex.synchronize { @connected = false }
          end

          # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
          def dispatch_raw(raw)
            sym = nil
            payload = decode(raw)
            return unless payload.is_a?(Hash)

            inner = payload['data'] || payload
            return unless inner.is_a?(Hash) && inner['e'] == 'bookTicker'

            sym = stream_to_symbol_upper(payload['stream']) || inner['s'].to_s.upcase
            return if sym.empty?

            pair = @symbol_to_pair[sym]
            quote = BookTickerWs.quote_from_book_ticker_payload(inner, coindcx_pair: pair, binance_symbol: sym)
            feed = @mutex.synchronize { @listeners[sym] }
            feed&.emit_quote(quote)
          rescue StandardError => e
            feed = sym && !sym.to_s.empty? ? @mutex.synchronize { @listeners[sym] } : nil
            if feed
              feed.emit_error(e)
            else
              @logger&.warn("[binance.multiplex.book_ticker] #{e.message}")
            end
          end
          # rubocop:enable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

          def stream_to_symbol_upper(stream)
            s = stream.to_s
            return nil unless s.include?('@')

            s.split('@', 2).first.upcase
          end

          def decode(raw)
            parsed = raw.is_a?(String) ? JSON.parse(raw) : raw
            parsed.is_a?(Hash) ? parsed : nil
          rescue JSON::ParserError
            nil
          end

          def fire_all_on_close(info)
            @mutex.synchronize { @listeners.values.dup }.each { |f| f.fire_on_close_async(info) }
          end

          def fire_all_on_error(err)
            @mutex.synchronize { @listeners.values.dup }.each { |f| f.fire_on_error_async(err) }
          end

          def default_transport
            require_relative 'depth_ws/websocket_client_simple_transport'
            DepthWs::WebsocketClientSimpleTransport.new(logger: @logger)
          end
        end

        class BookStreamFeed
          def initialize(partition:, symbol_upper:, coindcx_pair:)
            @partition = partition
            @symbol_upper = symbol_upper.to_s.upcase
            @coindcx_pair = coindcx_pair.to_s
            @on_quote = nil
            @on_open = nil
            @on_close = nil
            @on_error = nil
            @attached = false
          end

          attr_reader :symbol_upper, :coindcx_pair

          def on_quote(&block)
            (@on_quote = block
             self)
          end

          def on_open(&block)
            (@on_open = block
             self)
          end

          def on_close(&block)
            (@on_close = block
             self)
          end

          def on_error(&block)
            (@on_error = block
             self)
          end

          def connect
            return self if @attached

            @partition.attach(self)
            @attached = true
            self
          end

          def disconnect
            return self unless @attached

            @partition.detach(self)
            @attached = false
            self
          end

          def emit_quote(quote)
            @on_quote&.call(quote)
          end

          def fire_on_open_async
            @on_open&.call
          end

          def fire_on_close_async(info)
            @on_close&.call(info)
          end

          def fire_on_error_async(err)
            @on_error&.call(err)
          end

          def emit_error(err)
            @on_error&.call(err)
          end

          def url
            @partition.url
          end
        end
      end
    end
  end
end
