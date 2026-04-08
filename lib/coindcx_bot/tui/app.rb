# frozen_string_literal: true

require 'pastel'
require 'tty-prompt'
require 'tty-table'
require 'tty-screen'
require 'tty-box'
require 'logger'

module CoindcxBot
  module Tui
    class App
      def self.start
        new.run
      end

      def run
        pastel = Pastel.new
        prompt = TTY::Prompt.new
        logger = Logger.new($stdout)
        config = CoindcxBot::Config.load
        engine = CoindcxBot::Core::Engine.new(config: config, logger: logger)

        worker = Thread.new do
          engine.run
        rescue StandardError => e
          logger.error("Engine: #{e.full_message}")
        end

        sleep 1.0

        loop do
          print_screen(engine.snapshot, pastel)
          cmd = prompt.select('Command', %w[refresh pause resume kill_on kill_off flatten quit], cycle: true)
          case cmd
          when 'refresh'
            next
          when 'pause'
            engine.pause!
          when 'resume'
            engine.resume!
          when 'kill_on'
            engine.kill_switch_on!
          when 'kill_off'
            engine.kill_switch_off!
          when 'flatten'
            engine.flatten_all!
          when 'quit'
            engine.request_stop!
            break
          end
        end

        worker.join(60)
      rescue CoindcxBot::Config::ConfigurationError => e
        warn e.message
        warn 'Copy config/bot.yml.example to config/bot.yml'
        exit 1
      end

      private

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
