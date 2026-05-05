# frozen_string_literal: true

require 'tty-cursor'
require 'tty-screen'
require 'stringio'
require_relative '../term_width'
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
            imb   = @imbalance[pair] || { value: 0.0, bias: :neutral }
            walls = @walls[pair] || { bids: [], asks: [] }
            w     = [TermWidth.columns, 40].max

            # Filter log events for the focused pair before indexing
            pair_log = @log.select { |ev| ev[:pair] == pair }.first(MAX_LOG_SIZE)

            buf = StringIO.new
            buf << @cursor.save

            # ── Top border with pill title ──────────────────────────────
            title = ui_header(' ORDERFLOW ENGINE ')
            rem = w - 2 - visible_len(title)
            l1 = (rem / 2).clamp(1, w)
            l2 = (rem - l1).clamp(1, w)
            buf << move(@row) << ui_border("┌#{'─' * l1}#{title}#{'─' * l2}┐")

            # ── Imbalance row ───────────────────────────────────────────
            imb_content = "Imbalance: #{format_imbalance(imb)}"
            buf << move(@row + 1) << ui_border('│ ') << pad_visible(imb_content, w - 4) << ui_border(' │')

            # ── Walls row ───────────────────────────────────────────────
            walls_content = "Walls:     #{format_walls(walls)}"
            buf << move(@row + 2) << ui_border('│ ') << pad_visible(walls_content, w - 4) << ui_border(' │')

            # ── Event log label row ─────────────────────────────────────
            buf << move(@row + 3) << ui_border('│ ') << pad_visible(muted('Recent Events:'), w - 4) << ui_border(' │')

            # ── Event log rows (pre-filtered, no gaps) ──────────────────
            MAX_LOG_SIZE.times do |i|
              ev = pair_log[i]
              content = ev ? "  #{format_event(ev)}" : muted('·')
              buf << move(@row + 4 + i) << ui_border('│ ') << pad_visible(content, w - 4) << ui_border(' │')
            end

            # ── Bottom border ───────────────────────────────────────────
            buf << move(@row + 4 + MAX_LOG_SIZE) << ui_border("└#{'─' * (w - 2)}┘")

            buf << @cursor.restore
            @output.print buf.string
            @output.flush
          end
        end

        def row_count
          # top border + imbalance + walls + events label + MAX_LOG_SIZE event rows + bottom border
          1 + 1 + 1 + 1 + MAX_LOG_SIZE + 1
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

          "#{color_func.call(format('%+.4f', val).ljust(8))} [#{muted(gauge)}] #{color_func.call(imb[:bias].to_s.upcase)}"
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
            when :orderflow_absorption     then method(:warning)
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
