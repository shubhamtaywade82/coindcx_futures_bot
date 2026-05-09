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

        def initialize(bus:, engine:, origin_row:, origin_col: 0, focus_pair_proc: nil, output: $stdout)
          @bus = bus
          @engine = engine
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
          pair = resolved_focus_pair
          return if pair.empty?

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

            left_w, right_w = split_widths(w)
            ai_lines = build_ai_lines(pair)

            # ── Imbalance row ───────────────────────────────────────────
            imb_content = "Imbalance: #{format_imbalance(imb)}"
            buf << move(@row + 1) << ui_border('│ ') << compose_row(imb_content, ai_lines[0], left_w, right_w) << ui_border(' │')

            # ── Walls row ───────────────────────────────────────────────
            walls_content = "Walls:     #{format_walls(walls)}"
            buf << move(@row + 2) << ui_border('│ ') << compose_row(walls_content, ai_lines[1], left_w, right_w) << ui_border(' │')

            # ── Event log label row ─────────────────────────────────────
            legend = 'Recent Events: THRU=executed, CANCEL=pulled/requoted'
            buf << move(@row + 3) << ui_border('│ ') << compose_row(muted(legend), muted('AI Analysis:'), left_w, right_w) << ui_border(' │')

            # ── Event log rows (pre-filtered, no gaps) ──────────────────
            MAX_LOG_SIZE.times do |i|
              ev = pair_log[i]
              left = ev ? "  #{format_event(ev)}" : muted('·')
              right = ai_lines[2 + i] || muted('·')
              buf << move(@row + 4 + i) << ui_border('│ ') << compose_row(left, right, left_w, right_w) << ui_border(' │')
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

        def resolved_focus_pair
          preferred = @focus_pair_proc&.call
          return preferred.to_s unless preferred.nil? || preferred.to_s.strip.empty?

          pairs = @engine&.snapshot&.pairs
          Array(pairs).first.to_s
        rescue StandardError
          ''
        end

        def split_widths(total_width)
          inner = total_width - 4
          right = (inner * 0.78).to_i.clamp(70, 120)
          left = inner - right - 1
          left = 16 if left < 16
          right = [inner - left - 1, 28].max if left + right + 1 > inner
          [left, right]
        end

        def compose_row(left_text, right_text, left_w, right_w)
          left = left_text.nil? ? muted('·') : left_text
          right = right_text.nil? ? muted('·') : right_text
          "#{pad_visible(left, left_w)}#{muted('│')}#{pad_visible(right, right_w)}"
        end

        def build_ai_lines(pair)
          ai = safe_ai_analysis_snapshot
          return [muted('AI: OFF')] unless ai.is_a?(Hash) && ai[:enabled]
          return [loss("AI ERR: #{truncate(ai[:rationale].to_s, 38)}")] if ai[:status].to_s == 'ERR'
          return [muted('AI: WAIT')] if ai[:status].to_s == 'WAIT'

          symbol = compact_pair_symbol((ai[:pair] || pair).to_s)
          side = ai[:side].to_s
          conf = format('%.1f%%', ai[:confidence_pct].to_f)
          zone = ai[:entry_zone].is_a?(Hash) ? ai[:entry_zone] : {}
          entry = format_range(zone[:min], zone[:max])
          sl = format_level(ai[:stop_loss])
          tp = Array(ai[:targets]).first(3).map { |v| format_level(v) }.reject(&:empty?).join(', ')
          levels = Array(ai[:levels_to_watch]).first(4).map { |v| format_level(v) }.reject(&:empty?).join(', ')
          updated = ai[:updated_at].is_a?(Time) ? ai[:updated_at].strftime('%H:%M:%S') : '—'
          side_disp = side == 'LONG' ? profit(side) : side == 'SHORT' ? loss(side) : muted(side)

          lines = [
            "#{bold('PAIR: ')}#{symbol} #{muted("· #{conf}")}",
            "#{bold('BIAS: ')}#{side_disp}",
            "#{bold('ENTRY: ')}#{entry}",
            "#{bold('SL: ')}#{sl.empty? ? '—' : sl}",
            "#{bold('TP: ')}#{tp.empty? ? '—' : tp}",
            "#{bold('WATCH: ')}#{levels.empty? ? '—' : levels}",
            "#{bold('WHY: ')}#{truncate(ai[:rationale].to_s, 40)}",
            "#{muted('UPD:')} #{updated}"
          ]
          while lines.length < (MAX_LOG_SIZE + 2)
            lines << muted('·')
          end
          lines
        rescue StandardError
          Array.new(MAX_LOG_SIZE + 2, muted('AI: —'))
        end

        def safe_ai_analysis_snapshot
          return {} unless @engine&.respond_to?(:snapshot)

          snap = @engine.snapshot
          return {} unless snap.respond_to?(:ai_analysis)

          snap.ai_analysis
        rescue StandardError
          {}
        end

        def compact_pair_symbol(pair)
          pair.to_s.sub(/^B-/, '').sub(/_USDT\z/i, '')
        end

        def format_range(min, max)
          lo = format_level(min)
          hi = format_level(max)
          return '—' if lo.empty? && hi.empty?
          return lo if hi.empty?
          return hi if lo.empty?

          "#{lo} - #{hi}"
        end

        def format_level(raw)
          return '' if raw.nil?

          format('%.2f', Float(raw))
        rescue ArgumentError, TypeError
          ''
        end

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
                shift = ev[:events].find { |event| event[:type].to_s.match?(/(pull|reduce)\z/) }
                format_liquidity_shift_event(shift)
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

        def format_liquidity_shift_event(event)
          return nil unless event

          action = event[:type].to_s.upcase
          price = event[:price]
          classification = event[:classification].to_s.upcase
          size = event[:size]
          base = "#{action} at #{price}"
          base = "#{base} (Vol: #{format('%.2f', size.to_f)})" if size
          return base if classification.empty?

          "#{base} · #{classification}"
        end

        def move(row)
          @cursor.move_to(@col, row)
        end
      end
    end
  end
end
