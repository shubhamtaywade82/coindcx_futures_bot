# frozen_string_literal: true

require 'tty-cursor'
require 'tty-screen'
require 'stringio'
require_relative '../theme'
require_relative '../ansi_string'

module CoindcxBot
  module Tui
    module Panels
      # Real-time Orderflow monitor: Imbalance, Walls, and Absorption.
      class OrderflowPanel
        include Theme
        include AnsiString

        MAX_LOG_SIZE = 5

        def initialize(bus:, origin_row:, origin_col: 0, focus_pair_proc: nil, output: $stdout)
          @bus = bus
          @row = origin_row
          @col = origin_col
          @focus_pair_proc = focus_pair_proc
          @output = output
          @cursor = TTY::Cursor

          @imbalance = {}   # pair => { value: Float, bias: Symbol }
          @walls     = {}   # pair => { bids: [], asks: [] }
          @log       = []   # Array of { type, pair, text, ts }
          @mutex     = Mutex.new

          subscribe_events
        end

        def render
          pair = @focus_pair_proc&.call&.to_s
          return unless pair

          @mutex.synchronize do
            imb = @imbalance[pair] || { value: 0.0, bias: :neutral }
            walls = @walls[pair] || { bids: [], asks: [] }
            w = [TTY::Screen.width || 80, 40].max

            buf = StringIO.new
            buf << @cursor.save
            buf << move(@row) << bold('ORDERFLOW ENGINE') << muted("  #{'─' * [w - 22, 8].max}")

            # Imbalance Gauge
            buf << move(@row + 1) << "Imbalance: #{format_imbalance(imb)}"

            # Walls
            buf << move(@row + 2) << "Walls:     #{format_walls(walls)}"

            # Event Log
            buf << move(@row + 3) << muted('Recent Events:')
            @log.first(MAX_LOG_SIZE).each_with_index do |ev, idx|
              next unless ev[:pair] == pair
              buf << move(@row + 4 + idx) << "  #{format_event(ev)}"
            end

            buf << @cursor.restore
            @output.print buf.string
            @output.flush
          end
        end

        def row_count
          4 + MAX_LOG_SIZE
        end

        private

        def subscribe_events
          @bus.subscribe(:orderflow_imbalance) do |ev|
            @mutex.synchronize { @imbalance[ev[:pair]] = { value: ev[:value], bias: ev[:bias] } }
          end

          @bus.subscribe(:orderflow_walls) do |ev|
            @mutex.synchronize { @walls[ev[:pair]] = { bids: ev[:bid_walls], asks: ev[:ask_walls] } }
          end

          %i[orderflow_absorption orderflow_spoof_activity orderflow_liquidity_shift].each do |type|
            @bus.subscribe(type) do |ev|
              add_to_log(type, ev)
            end
          end
        end

        def add_to_log(type, ev)
          @mutex.synchronize do
            text =
              case type
              when :orderflow_absorption
                "ABSORPTION at #{ev[:price]} (Vol: #{ev[:volume]})"
              when :orderflow_spoof_activity
                "SPOOF #{ev[:events].first[:side]} at #{ev[:events].first[:price]}"
              when :orderflow_liquidity_shift
                pull = ev[:events].find { |e| e[:type].to_s.end_with?('pull') }
                pull ? "PULL #{pull[:type].to_s.upcase} at #{pull[:price]}" : nil
              end

            next unless text

            @log.unshift(pair: ev[:pair], type: type, text: text, ts: Time.now)
            @log.pop if @log.size > 20
          end
        end

        def format_imbalance(imb)
          val = imb[:value]
          color_func =
            case imb[:bias]
            when :bullish then method(:profit)
            when :bearish then method(:loss)
            else method(:muted)
            end

          # Simple gauge: [-----|-----]
          gauge_width = 20
          pos = ((val + 1.0) / 2.0 * gauge_width).round
          pos = [0, [pos, gauge_width].min].max
          gauge = +''
          gauge_width.times do |i|
            gauge << (i == pos ? '█' : '─')
          end

          "#{color_func.call(val.to_s.ljust(6))} [#{gauge}] #{imb[:bias].to_s.upcase}"
        end

        def format_walls(walls)
          b = walls[:bids].size
          a = walls[:asks].size
          return muted('None') if b == 0 && a == 0

          "#{profit("Bids: #{b}")}  #{loss("Asks: #{a}")}"
        end

        def format_event(ev)
          time = ev[:ts].strftime('%H:%M:%S')
          col =
            case ev[:type]
            when :orderflow_absorption then method(:warning)
            when :orderflow_spoof_activity then method(:loss)
            else method(:muted)
            end
          "#{muted(time)} #{col.call(ev[:text])}"
        end

        def move(row)
          @cursor.move_to(@col, row)
        end
      end
    end
  end
end
