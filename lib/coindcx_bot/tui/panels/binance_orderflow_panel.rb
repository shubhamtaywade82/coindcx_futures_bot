# frozen_string_literal: true

require 'bigdecimal'
require 'tty-cursor'
require 'tty-screen'
require 'set'
require 'stringio'
require_relative '../term_width'
require_relative '../theme'
require_relative '../ansi_string'

module CoindcxBot
  module Tui
    module Panels
      # Binance-only orderflow + divergence (read-only shadow feed). Never mixed with CoinDCX execution UI.
      class BinanceOrderflowPanel
        include Theme
        include AnsiString

        MAX_WALLS_SIDE = 5
        DISPLAY_WALL_ROWS = 3
        SWEEP_RING = 8
        ICEBERG_RING = 5
        EVENT_RING = 6

        attr_accessor :visible

        def initialize(bus:, engine:, origin_row:, origin_col: 0, focus_pair_proc: nil, output: $stdout, visible: true)
          @bus = bus
          @engine = engine
          @row = origin_row
          @col = origin_col
          @focus_pair_proc = focus_pair_proc
          @output = output
          @visible = visible
          @cursor = TTY::Cursor
          @mutex = Mutex.new

          @imbalance = {} # pair => { value:, bias:, source: }
          @walls_bid = {} # key => { price:, size:, score:, ts:, side: :bid }
          @walls_ask = {}
          @divergence = {} # pair => { label:, bps:, age_ms:, reason: }
          @sweep_ring = []
          @iceberg_ring = []
          @event_ring = []

          subscribe_events
        end

        def row_count
          return 0 unless @visible

          # top + div + imb + wall_hdr + DISPLAY_WALL_ROWS + evt_hdr + EVENT_RING + bot
          1 + 1 + 1 + 1 + DISPLAY_WALL_ROWS + 1 + EVENT_RING + 1
        end

        def render
          return unless @visible

          pair = resolved_focus_pair
          return if pair.empty?

          @mutex.synchronize do
            w = [TermWidth.columns, 40].max
            buf = StringIO.new
            buf << @cursor.save

            title = ui_header(' BINANCE ORDERFLOW ')
            rem = w - 2 - visible_len(title)
            l1 = (rem / 2).clamp(1, w)
            l2 = (rem - l1).clamp(1, w)
            buf << move(@row) << ui_border("┌#{'─' * l1}#{title}#{'─' * l2}┐")

            div = divergence_line_for(pair)
            buf << move(@row + 1) << ui_border('│ ') << pad_visible(div, w - 4) << ui_border(' │')

            imb = imbalance_line_for(pair)
            buf << move(@row + 2) << ui_border('│ ') << pad_visible(imb, w - 4) << ui_border(' │')

            buf << move(@row + 3) << ui_border('│ ') << pad_visible(muted('Walls (Binance shadow · top 3 by score)'), w - 4) << ui_border(' │')

            wall_rows = format_wall_rows(pair)
            DISPLAY_WALL_ROWS.times do |i|
              buf << move(@row + 4 + i) << ui_border('│ ') << pad_visible(wall_rows[i] || muted('·'), w - 4) << ui_border(' │')
            end

            buf << move(@row + 4 + DISPLAY_WALL_ROWS) << ui_border('│ ') << pad_visible(muted('Recent (sweeps / icebergs / void / zone)'), w - 4) << ui_border(' │')

            EVENT_RING.times do |i|
              line = event_line(i)
              buf << move(@row + 5 + DISPLAY_WALL_ROWS + i) << ui_border('│ ') << pad_visible(line, w - 4) << ui_border(' │')
            end

            buf << move(@row + row_count - 1) << ui_border("└#{'─' * (w - 2)}┘")
            buf << @cursor.restore
            @output.print buf.string
            @output.flush
          end
        end

        def reposition!(row)
          @row = row
        end

        private

        def resolved_focus_pair
          preferred = @focus_pair_proc&.call
          return preferred.to_s unless preferred.nil? || preferred.to_s.strip.empty?

          pairs = @engine&.snapshot&.pairs
          Array(pairs).first.to_s
        rescue StandardError
          ''
        end

        def binance_source?(src)
          s = src.to_s.downcase
          s == 'binance' || src == :binance
        end

        def subscribe_events
          @bus.subscribe(:'liquidity.wall.detected') { |ev| handle_wall(:detected, ev) }
          @bus.subscribe(:'liquidity.wall.removed') { |ev| handle_wall(:removed, ev) }
          @bus.subscribe(:'liquidity.sweep.detected') { |ev| handle_sweep(ev) }
          @bus.subscribe(:'liquidity.iceberg.suspected') { |ev| handle_iceberg(ev) }
          @bus.subscribe(:'liquidity.void.detected') { |ev| handle_void(ev) }
          @bus.subscribe(:'liquidity.zone.confirmed') { |ev| handle_zone(ev) }
          @bus.subscribe(:orderflow_imbalance) { |ev| handle_imbalance(ev) }

          %w[risk.divergence.ok risk.divergence.exceeded risk.divergence.recovered].each do |evname|
            @bus.subscribe(evname) { |payload| handle_divergence(evname, payload) }
          end
        end

        def handle_imbalance(ev)
          return unless binance_source?(ev[:source])

          @mutex.synchronize do
            @imbalance[ev[:pair].to_s] = { value: ev[:value], bias: ev[:bias], source: ev[:source] }
          end
        end

        def handle_wall(kind, ev)
          return unless binance_source?(ev[:source])

          pair = (ev[:pair] || ev[:symbol]).to_s
          side = ev[:side].to_sym
          store = side == :ask ? @walls_ask : @walls_bid
          key = wall_row_key(pair, side, ev[:price])

          @mutex.synchronize do
            if kind == :detected
              store[key] = {
                price: BigDecimal(ev[:price].to_s),
                size: BigDecimal(ev[:size].to_s),
                score: ev[:score].to_f,
                ts: Integer(ev[:ts] || (Time.now.to_f * 1000)),
                side: side,
                pair: pair
              }
              trim_walls!(store)
            else
              store.delete(key)
            end
          end
        end

        def wall_row_key(pair, side, price)
          "#{pair}|#{side}|#{BigDecimal(price.to_s).to_s('F')}"
        end

        def trim_walls!(store)
          return if store.size <= MAX_WALLS_SIDE

          sorted = store.values.sort_by { |r| -r[:score].to_f }
          keep_keys = sorted.first(MAX_WALLS_SIDE).map { |r| wall_row_key(r[:pair], r[:side], r[:price]) }.to_set
          store.keep_if { |k, _| keep_keys.include?(k) }
        end

        def handle_sweep(ev)
          return unless binance_source?(ev[:source])

          @mutex.synchronize do
            @sweep_ring << { kind: :sweep, at: Time.now, payload: ev }
            @sweep_ring.shift while @sweep_ring.size > SWEEP_RING
            push_event_ring(:sweep, ev)
          end
        end

        def handle_iceberg(ev)
          return unless binance_source?(ev[:source])

          @mutex.synchronize do
            @iceberg_ring << { kind: :iceberg, at: Time.now, payload: ev }
            @iceberg_ring.shift while @iceberg_ring.size > ICEBERG_RING
            push_event_ring(:iceberg, ev)
          end
        end

        def handle_void(ev)
          return unless binance_source?(ev[:source])

          @mutex.synchronize { push_event_ring(:void, ev) }
        end

        def handle_zone(ev)
          return unless binance_source?(ev[:source])

          @mutex.synchronize { push_event_ring(:zone, ev) }
        end

        def push_event_ring(kind, ev)
          label =
            case kind
            when :sweep then 'SWEEP'
            when :iceberg then 'ICE'
            when :void then 'VOID'
            when :zone then 'ZONE'
            else 'EVT'
            end
          @event_ring << { kind: kind, label: label, at: Time.now, ev: ev }
          @event_ring.shift while @event_ring.size > EVENT_RING
        end

        def handle_divergence(name, payload)
          pair = payload[:pair].to_s
          return if pair.empty?

          @mutex.synchronize do
            case name
            when 'risk.divergence.ok', 'risk.divergence.recovered'
              @divergence[pair] = {
                label: 'OK',
                bps: payload[:bps],
                age_ms: payload[:age_ms],
                reason: nil
              }
            when 'risk.divergence.exceeded'
              reason = (payload[:reason] || :exceeded).to_sym
              label = stale_reason?(reason) ? 'STALE' : 'EXCEEDED'
              @divergence[pair] = {
                label: label,
                bps: payload[:bps],
                age_ms: payload[:age_ms],
                reason: reason
              }
            end
          end
        end

        def stale_reason?(reason)
          %i[binance_stale coindcx_stale].include?(reason) || reason.to_s.include?('stale')
        end

        def divergence_line_for(pair)
          d = @divergence[pair]
          unless d
            return muted('Divergence: — (awaiting Binance bookTicker + CoinDCX mid)')
          end

          bps = d[:bps].nil? ? '—' : format('%.2f', d[:bps].to_f)
          age = d[:age_ms].nil? ? '—' : "#{d[:age_ms]}ms"
          core = "Divergence: #{d[:label]}  bps=#{bps}  age=#{age}"
          styled =
            case d[:label]
            when 'OK' then profit(core)
            when 'EXCEEDED' then loss(on_red(" #{core} "))
            when 'STALE' then warning(core)
            else muted(core)
            end
          bold(styled) + muted("  pair=#{compact_pair(pair)}")
        end

        def compact_pair(p)
          p.to_s.sub(/^B-/, '').sub(/_USDT\z/i, '')
        end

        def imbalance_line_for(pair)
          im = @imbalance[pair]
          return muted('Imbalance: —') unless im

          val = im[:value].to_f
          bias = im[:bias].to_sym
          color =
            case bias
            when :bullish then method(:profit)
            when :bearish then method(:loss)
            else method(:muted)
            end
          gauge_width = 18
          pos = ((val + 1.0) / 2.0 * gauge_width).round.clamp(0, gauge_width)
          gauge = +''
          gauge_width.times { |i| gauge << (i == pos ? '█' : '─') }
          "#{color.call("Imb #{format('%+.3f', val)} #{bias.to_s.upcase}")} #{muted("[#{gauge}]")}"
        end

        def format_wall_rows(pair)
          bids = @walls_bid.values.select { |r| r[:pair] == pair }.sort_by { |r| -r[:score].to_f }.first(DISPLAY_WALL_ROWS)
          asks = @walls_ask.values.select { |r| r[:pair] == pair }.sort_by { |r| -r[:score].to_f }.first(DISPLAY_WALL_ROWS)
          rows = []
          DISPLAY_WALL_ROWS.times do |i|
            b = bids[i]
            a = asks[i]
            left = b ? wall_cell(b, :bid) : muted('—')
            right = a ? wall_cell(a, :ask) : muted('—')
            rows << "#{profit('BID')} #{left}  #{muted('│')}  #{loss('ASK')} #{right}"
          end
          rows
        end

        def wall_cell(row, side)
          age_s = wall_age_s(row[:ts])
          px = row[:price].to_s('F')
          sc = format('%.1f×', row[:score])
          base = "#{px} sz=#{row[:size].to_s('F')} sc=#{sc} #{muted(age_s)}"
          side == :bid ? profit(base) : loss(base)
        end

        def wall_age_s(ts_ms)
          dt = (Time.now.to_f * 1000).to_i - ts_ms.to_i
          dt.negative? ? '0s' : "#{dt / 1000}s"
        rescue StandardError
          ''
        end

        def event_line(idx)
          ent = @event_ring[idx]
          return muted('·') unless ent

          ev = ent[:ev]
          pair = (ev[:pair] || ev[:symbol]).to_s
          t = ent[:at].strftime('%H:%M:%S')
          body =
            case ent[:kind]
            when :sweep
              loss("#{ent[:label]} #{compact_pair(pair)} #{ev[:side]} lv=#{ev[:levels_swept]} notional=#{ev[:notional]}")
            when :iceberg
              cyan("#{ent[:label]} #{compact_pair(pair)} #{ev[:side]} @#{ev[:price]} sc=#{ev[:score]}")
            when :void
              warning("#{ent[:label]} #{compact_pair(pair)} #{ev[:side]} #{ev[:void_start]}-#{ev[:void_end]}")
            when :zone
              muted("#{ent[:label]} #{compact_pair(pair)} band=#{ev[:price_band]} touches=#{ev[:touch_count]}")
            else
              muted(ent[:label].to_s)
            end
          "#{muted(t)} #{body}"
        end

        def move(row)
          @cursor.move_to(@col, row)
        end
      end
    end
  end
end
