# frozen_string_literal: true

require 'bigdecimal'
require 'tty-cursor'
require 'tty-screen'
require 'stringio'
require_relative '../theme'
require_relative '../ansi_string'

module CoindcxBot
  module Tui
    module Panels
      class DeskRiskStrategyPanel
        include Theme
        include AnsiString

        def initialize(engine:, tick_store:, symbols:, origin_row:, origin_col: 0, output: $stdout)
          @engine = engine
          @tick_store = tick_store
          @symbols = Array(symbols).map(&:to_s)
          @row = origin_row
          @col = origin_col
          @output = output
          @cursor = TTY::Cursor
        end

        def render
          vm = DeskViewModel.build(engine: @engine, tick_store: @tick_store, symbols: @symbols)
          snap = @engine.snapshot
          w = [TTY::Screen.width || 80, 40].max

          buf = StringIO.new
          buf << @cursor.save
          buf << move(@row) << bold('RISK ENGINE') << muted("  #{'─' * [w - 15, 8].max}")
          buf << move(@row + 1) << clr(risk_line_one(vm, snap))
          buf << move(@row + 2) << clr(risk_line_two(vm, snap))
          buf << move(@row + 3) << clr(muted('─' * [w - 1, 40].max))
          buf << move(@row + 4) << bold('SIGNAL + STRATEGY') << muted("  #{'─' * [w - 20, 6].max}")
          buf << move(@row + 5) << clr(strategy_line(vm))
          buf << @cursor.restore

          @output.print buf.string
          @output.flush
        end

        def row_count
          6
        end

        private

        def risk_line_one(vm, snap)
          max_l = max_daily_loss_s
          loss_amt = snap.daily_pnl.negative? ? -snap.daily_pnl : BigDecimal('0')
          util = vm.loss_utilization_pct
          util_s =
            if util.nil?
              '—'
            else
              format('%.1f%%', util.to_f)
            end
          join_parts(
            [
              "#{bold('MAX LOSS: ')}#{max_l}",
              "#{bold('CURR LOSS: ')}#{fmt_inr(loss_amt)}",
              "#{bold('UTIL: ')}#{util_s}"
            ]
          )
        end

        def risk_line_two(vm, snap)
          open_n = vm.display_open_positions_count
          ord_n = Array(snap.working_orders).size
          slip = vm.paper_slippage_total
          slip_part =
            if slip.nil?
              muted('SLIP: —')
            else
              "#{bold('SLIP: ')}#{fmt_num(slip)}"
            end

          join_parts(
            [
              "#{bold('POS RISK: ')}#{risk_position_ok?(open_n, snap) ? profit('OK') : warning('WATCH')}",
              "#{bold('OPEN: ')}#{open_n} #{muted('|')} #{bold('WORK ORD: ')}#{ord_n}",
              slip_part,
              "#{bold('BAND: ')}#{color_risk_band(vm.risk_band)}"
            ]
          )
        end

        def risk_position_ok?(open_n, snap)
          max_p = @engine.config.risk[:max_open_positions]
          return true if max_p.nil?

          open_n <= max_p.to_i
        rescue ArgumentError, TypeError
          true
        end

        def strategy_line(vm)
          join_parts(
            [
              "#{bold('STRATEGY: ')}#{accent(vm.strategy_name)}",
              "#{bold('STATE: ')}#{muted(vm.strategy_position_state)}",
              "#{bold('SIGNAL: ')}#{muted(vm.strategy_signal_summary)}"
            ]
          )
        end

        def max_daily_loss_s
          fmt_inr(BigDecimal(@engine.config.resolved_max_daily_loss_inr.to_s))
        rescue ArgumentError, TypeError
          muted('—')
        end

        def fmt_inr(v)
          "₹#{format('%.2f', v)}"
        end

        def fmt_num(v)
          format('%.4f', BigDecimal(v.to_s))
        rescue ArgumentError, TypeError
          '—'
        end

        def join_parts(parts)
          parts.join(muted('  │  '))
        end

        def move(row)
          @cursor.move_to(@col, row)
        end

        def clr(content)
          "#{content}\e[K"
        end
      end
    end
  end
end
