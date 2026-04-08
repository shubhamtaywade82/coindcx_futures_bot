# frozen_string_literal: true

require 'pastel'
require 'tty-box'
require 'tty-logger'
require 'tty-screen'
require 'tty-table'

module CoindcxBot
  module Tui
    class App
      REFRESH_SECONDS = 2

      def self.start
        new.run
      end

      def run
        pastel = Pastel.new
        logger = TTY::Logger.new($stdout)
        config = CoindcxBot::Config.load
        engine = CoindcxBot::Core::Engine.new(config: config, logger: logger)

        worker = Thread.new do
          engine.run
        rescue StandardError => e
          logger.error("Engine: #{e.full_message}")
        end

        sleep 1.0
        quit_ui = false

        until quit_ui
          print_screen(engine.snapshot, pastel)
          puts pastel.dim("Keys: q quit | p pause | r resume | k kill on | o kill off | f flatten | . refresh (#{REFRESH_SECONDS}s)")
          ready = IO.select([$stdin], nil, nil, REFRESH_SECONDS)
          next unless ready

          cmd = $stdin.getc
          quit_ui = dispatch(engine, cmd)
        end

        engine.request_stop!
        worker.join(5)
      rescue CoindcxBot::Config::ConfigurationError => e
        warn e.message
        warn 'Copy config/bot.yml.example to config/bot.yml'
        exit 1
      end

      private

      def dispatch(engine, cmd)
        case cmd
        when 'q', 'Q', "\u0003" # Ctrl-C as char if raw
          true
        when 'p'
          engine.pause!
          false
        when 'r'
          engine.resume!
          false
        when 'k'
          engine.kill_switch_on!
          false
        when 'o'
          engine.kill_switch_off!
          false
        when 'f'
          engine.flatten_all!
          false
        else
          false
        end
      end

      def print_screen(snap, pastel)
        system('clear') || system('cls')

        title = pastel.bold("CoinDCX bot  #{snap.dry_run ? '[DRY_RUN]' : ''}")
        puts TTY::Box.frame(width: TTY::Screen.width, padding: 1, title: { top_left: title }) do
          lines = []
          lines << "running=#{snap.running} paused=#{snap.paused} kill=#{snap.kill_switch} stale=#{snap.stale}"
          lines << "daily_pnl_inr=#{snap.daily_pnl.to_s('F')} last_error=#{snap.last_error.inspect}"
          snap.pairs.each do |p|
            t = snap.ticks[p]
            lines << "  #{p}  ltp=#{t[:price]&.to_s('F')}  at=#{t[:at]}"
          end
          lines << ''
          lines << table_positions(snap.positions)
          lines.join("\n")
        end
      end

      def table_positions(positions)
        return '(no open journal positions)' if positions.empty?

        header = %w[id pair side qty entry stop partial]
        rows = positions.map do |r|
          [
            r[:id],
            r[:pair],
            r[:side],
            r[:quantity],
            r[:entry_price],
            r[:stop_price],
            r[:partial_done]
          ]
        end
        TTY::Table.new(header, rows).render(:unicode)
      end
    end
  end
end
