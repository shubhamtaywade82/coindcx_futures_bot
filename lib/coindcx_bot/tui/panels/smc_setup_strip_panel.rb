# frozen_string_literal: true

require 'tty-cursor'
require 'stringio'
require_relative '../term_width'
require_relative '../theme'
require_relative '../ansi_string'

module CoindcxBot
  module Tui
    module Panels
      # SMC TradeSetup planner (Ollama) + active FSM rows — separate from REGIME strip (HMM / regime.ai).
      class SmcSetupStripPanel
        include Theme
        include AnsiString

        def initialize(engine:, origin_row:, origin_col: 0, output: $stdout)
          @engine = engine
          @row = origin_row
          @col = origin_col
          @output = output
          @cursor = TTY::Cursor
        end

        def render
          snap = @engine.snapshot
          s = snap.smc_setup
          s = SmcSetup::TuiOverlay::DISABLED if s.nil? || !s.is_a?(Hash)

          buf = StringIO.new
          buf << @cursor.save
          if !truthy?(s[:enabled])
            buf << move(@row) << clr(line_off(term_width))
            buf << @cursor.restore
            @output.print buf.string
            @output.flush
            return
          end

          buf << move(@row) << clr(line_planner(s, term_width))
          buf << move(@row + 1) << clr(line_setups(s, term_width))
          buf << @cursor.restore
          @output.print buf.string
          @output.flush
        end

        def row_count
          s = @engine.snapshot.smc_setup
          s = SmcSetup::TuiOverlay::DISABLED if s.nil? || !s.is_a?(Hash)
          truthy?(s[:enabled]) ? 2 : 1
        end

        private

        def truthy?(v)
          v == true || v.to_s.downcase == 'true' || v.to_s == '1'
        end

        def term_width
          TermWidth.columns
        end

        def line_off(w)
          colored = "#{bold('SMC·SETUP')} #{muted('off')}  #{muted('·')}  #{muted('bot.yml smc_setup.enabled')}"
          p = strip_ansi(colored)
          return colored if p.length <= w

          "#{p[0, w - 1]}…"
        end

        def line_planner(s, w)
          plan_on = truthy?(s[:planner_enabled])
          plan_s = plan_on ? profit('PLANNER·ON') : muted('PLANNER·OFF')
          gk = truthy?(s[:gatekeeper_enabled]) ? warning('GK·ON') : muted('GK·OFF')
          ax = truthy?(s[:auto_execute]) ? accent('AUTO·EXE') : muted('AUTO·OFF')
          last = muted(format_last_run(s[:planner_last_at], s[:planner_interval_s]))
          err = s[:planner_error].to_s.strip
          err_part = err.empty? ? nil : loss("ERR: #{err[0, 56]}")
          colored = [bold('SMC·SETUP'), plan_s, gk, ax, last, err_part].compact.join('  ')
          p = strip_ansi(colored)
          return colored if p.length <= w

          "#{p[0, w - 1]}…"
        end

        def line_setups(s, w)
          rows = Array(s[:active_setups])
          if rows.empty?
            plain = '(no active TradeSetups — wait for planner or: bin/bot smc-setup plan-once)'
            t = plain.length > w ? "#{plain[0, w - 1]}…" : plain
            return muted(t)
          end

          parts = rows.first(5).map do |r|
            gid = (r[:setup_id] || r['setup_id']).to_s
            gid = "#{gid[0, 10]}…" if gid.length > 12
            pair = (r[:pair] || r['pair']).to_s.sub(/\AB-/, '')
            st = (r[:state] || r['state']).to_s
            dir = (r[:direction] || r['direction']).to_s[0, 1].upcase
            "#{gid}/#{pair}/#{st}/#{dir}"
          end
          extra = s[:active_count].to_i > 5 ? " +#{s[:active_count].to_i - 5}" : ''
          plain = "ACTIVE: #{parts.join(' | ')}#{extra}"
          colored = "#{bold('ACTIVE:')} #{parts.join(muted(' | '))}#{muted(extra)}"
          return colored if plain.length <= w

          "#{plain[0, w - 1]}…"
        end

        def format_last_run(at, interval_s)
          return 'LAST: —' if at.nil?

          sec = (Time.now - at).to_i
          return 'LAST: just now' if sec < 5

          if sec < 120
            "LAST: #{sec}s ago"
          else
            "LAST: #{(sec / 60).round}m ago (Δ#{interval_s.to_i}s)"
          end
        end

        def move(row)
          @cursor.move_to(@col, row)
        end

        def clr(content)
          "\e[0m#{content}\e[K"
        end
      end
    end
  end
end
