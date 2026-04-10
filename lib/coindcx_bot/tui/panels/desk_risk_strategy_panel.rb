# frozen_string_literal: true

require 'bigdecimal'
require 'tty-cursor'
require 'tty-screen'
require 'stringio'

module CoindcxBot
  module Tui
    module Panels
      class DeskRiskStrategyPanel
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
          buf << move(@row) << bold('RISK ENGINE') << dim("  #{'─' * [w - 15, 8].max}")
          buf << move(@row + 1) << clear_line(risk_line_one(vm, snap))
          buf << move(@row + 2) << clear_line(risk_line_two(vm, snap))
          buf << move(@row + 3) << clear_line(dim('─' * [w - 1, 40].max))
          buf << move(@row + 4) << bold('SIGNAL + STRATEGY') << dim("  #{'─' * [w - 20, 6].max}")
          buf << move(@row + 5) << clear_line(strategy_line(vm))
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
          loss = snap.daily_pnl.negative? ? -snap.daily_pnl : BigDecimal('0')
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
              "#{bold('CURR LOSS: ')}#{fmt_inr(loss)}",
              "#{bold('UTIL: ')}#{util_s}"
            ]
          )
        end

        def risk_line_two(vm, snap)
          open_n = Array(snap.positions).size
          ord_n = Array(snap.working_orders).size
          slip = vm.paper_slippage_total
          slip_part =
            if slip.nil?
              dim('SLIP: —')
            else
              "#{bold('SLIP: ')}#{fmt_num(slip)}"
            end

          join_parts(
            [
              "#{bold('POS RISK: ')}#{risk_position_ok?(open_n, snap) ? green('OK') : yellow('WATCH')}",
              "#{bold('OPEN: ')}#{open_n} #{dim('|')} #{bold('WORK ORD: ')}#{ord_n}",
              slip_part,
              "#{bold('BAND: ')}#{color_band(vm.risk_band)}"
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
              "#{bold('STRATEGY: ')}#{cyan(vm.strategy_name)}",
              "#{bold('STATE: ')}#{dim(vm.strategy_position_state)}",
              "#{bold('SIGNAL: ')}#{dim(vm.strategy_signal_summary)}"
            ]
          )
        end

        def max_daily_loss_s
          fmt_inr(BigDecimal(@engine.config.resolved_max_daily_loss_inr.to_s))
        rescue ArgumentError, TypeError
          dim('—')
        end

        def fmt_inr(v)
          "₹#{format('%.2f', v)}"
        end

        def fmt_num(v)
          format('%.4f', BigDecimal(v.to_s))
        rescue ArgumentError, TypeError
          '—'
        end

        def color_band(band)
          case band
          when 'CRIT' then on_red(" #{band} ")
          when 'HIGH' then red(band)
          when 'MED' then yellow(band)
          else green(band)
          end
        end

        def join_parts(parts)
          parts.join(dim('  │  '))
        end

        def move(row)
          @cursor.move_to(@col, row)
        end

        def clear_line(content)
          "#{content}\e[K"
        end

        def bold(str)   = "\e[1m#{str}\e[0m"
        def cyan(str)   = "\e[36m#{str}\e[0m"
        def green(str)  = "\e[32m#{str}\e[0m"
        def yellow(str) = "\e[33m#{str}\e[0m"
        def red(str)    = "\e[31m#{str}\e[0m"
        def dim(str)    = "\e[2m#{str}\e[0m"
        def on_red(str) = "\e[41;37m#{str}\e[0m"
      end
    end
  end
end
