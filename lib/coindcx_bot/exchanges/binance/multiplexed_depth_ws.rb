# frozen_string_literal: true

require 'bigdecimal'
require 'json'

module CoindcxBot
  module Exchanges
    module Binance
      # Multiplexed USDⓈ-M Futures depth: one (or more) sockets for many symbols.
      # Binance documents a soft cap of ~25 streams per connection; this client partitions
      # with +max_symbols_per_socket+ (default 25).
      #
      # Per-symbol feeds implement the same surface as +DepthWs+ used by +ResyncManager+:
      # +connect+, +disconnect+, +on_event+, +on_open+, +on_close+, +on_error+, +url+.
      class MultiplexedDepthWs
        DEFAULT_HOST = DepthWs::DEFAULT_HOST

        # +symbols+ — Binance linear symbols in UPPER (e.g. %w[BTCUSDT ETHUSDT]).
        def initialize(symbols:, base_ws: DEFAULT_HOST, max_symbols_per_socket: 25, logger: nil, transport: nil)
          @base_ws = base_ws.to_s.strip.chomp('/')
          @logger = logger
          @transport_template = transport
          @chunks = normalize_and_chunk(symbols, max_symbols_per_socket)
          @partitions = @chunks.map { |chunk| Partition.new(chunk, base_ws: @base_ws, logger: @logger, transport: @transport_template) }
          @symbol_to_partition = {}
          @chunks.flatten.each { |sym| @symbol_to_partition[sym] = @partitions.find { |p| p.symbols.include?(sym) } }
          @feeds = @chunks.flatten.to_h { |sym| [sym, StreamFeed.new(partition: @symbol_to_partition[sym], symbol_upper: sym)] }
        end

        def stream_for(binance_symbol_upper)
          @feeds.fetch(binance_symbol_upper.to_s.upcase)
        end

        # Eagerly open all partition sockets (optional; +StreamFeed#connect+ opens on demand).
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

        private

        def normalize_and_chunk(symbols, max_per)
          list = []
          Array(symbols).each do |s|
            u = s.to_s.strip.upcase
            list << u if !u.empty? && !list.include?(u)
          end
          raise ArgumentError, 'multiplexed depth requires at least one symbol' if list.empty?

          m = Integer(max_per.to_s)
          m = 25 if m < 1

          list.each_slice(m).to_a
        end

        # One websocket carrying +symbols+ (UPPER) @depth@100ms streams.
        class Partition
          def initialize(symbols_upper, base_ws:, logger:, transport:)
            @symbols = symbols_upper.map { |s| s.to_s.upcase }
            @logger = logger
            @transport_template = transport
            @listeners = {} # UPPER symbol => StreamFeed
            @mutex = Mutex.new
            @open_gate = Mutex.new
            @transport = nil
            @connected = false
            stream_path = @symbols.map { |s| "#{s.downcase}@depth@100ms" }.join('/')
            @url = "#{base_ws}/stream?streams=#{stream_path}"
          end

          attr_reader :url, :symbols

          def attach(feed)
            sym = feed.symbol_upper
            raise ArgumentError, "#{sym} not in partition #{@symbols.inspect}" unless @symbols.include?(sym)

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
            return unless inner.is_a?(Hash) && inner['e'] == 'depthUpdate'

            sym = stream_to_symbol_upper(payload['stream']) || inner['s'].to_s.upcase
            return if sym.empty?

            ev = DepthWs.build_depth_event(inner)
            feed = @mutex.synchronize { @listeners[sym] }
            feed&.emit_event(ev)
          rescue StandardError => e
            feed = sym && !sym.to_s.empty? ? @mutex.synchronize { @listeners[sym] } : nil
            if feed
              feed.emit_error(e)
            else
              @logger&.warn("[binance.multiplex.depth] #{e.message}")
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
            feeds = @mutex.synchronize { @listeners.values.dup }
            feeds.each { |f| f.fire_on_close_async(info) }
          end

          def fire_all_on_error(err)
            feeds = @mutex.synchronize { @listeners.values.dup }
            feeds.each { |f| f.fire_on_error_async(err) }
          end

          def default_transport
            require_relative 'depth_ws/websocket_client_simple_transport'
            DepthWs::WebsocketClientSimpleTransport.new(logger: @logger)
          end
        end

        # Per-symbol adapter compatible with +ResyncManager+.
        class StreamFeed
          def initialize(partition:, symbol_upper:)
            @partition = partition
            @symbol_upper = symbol_upper.to_s.upcase
            @on_event = nil
            @on_open = nil
            @on_close = nil
            @on_error = nil
            @attached = false
          end

          attr_reader :symbol_upper

          def on_event(&block)
            (@on_event = block
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

          def emit_event(event)
            @on_event&.call(event)
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
