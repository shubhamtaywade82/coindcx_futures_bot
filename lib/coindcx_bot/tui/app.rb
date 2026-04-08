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
        $stdout.sync = true
        $stderr.sync = true
        pastel = Pastel.new
        logger = TTY::Logger.new(output: $stdout)
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

        lines = []
        lines << pastel.bold("CoinDCX bot  #{snap.dry_run ? '[DRY_RUN]' : ''}")
        lines << "running=#{snap.running} paused=#{snap.paused} kill=#{snap.kill_switch} stale=#{snap.stale}"
        lines << "daily_pnl_inr=#{snap.daily_pnl.to_s('F')} last_error=#{snap.last_error.inspect}"
        snap.pairs.each do |p|
          tick = snap.ticks[p] || {}
          price = tick[:price]
          at = tick[:at]
          lines << "  #{p}  ltp=#{price ? price.to_s('F') : '—'}  at=#{at || '—'}"
        end
        if snap.pairs.any? { |p| (snap.ticks[p] || {})[:price].nil? } && snap.last_error.nil?
          lines << pastel.yellow('  (no WS price yet — check API keys, pair codes, and network)')
        end
        lines << ''
        lines << table_positions(snap.positions)

        body = lines.join("\n")
        width = TTY::Screen.width
        width = 80 if width.nil? || width < 40

        begin
          framed = TTY::Box.frame(width: width, padding: 1, title: { top_left: 'CoinDCX' }) { body }
          puts framed
        rescue StandardError
          puts body
        end
        $stdout.flush
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
