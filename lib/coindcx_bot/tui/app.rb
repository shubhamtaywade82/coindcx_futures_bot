# frozen_string_literal: true

require 'tty-cursor'
require 'tty-logger'
require 'tty-screen'

module CoindcxBot
  module Tui
    class App
      RENDER_INTERVAL = 0.25
      KEYBOARD_POLL   = 1

      def self.start
        new.run
      end

      def run
        setup_terminal
        config     = CoindcxBot::Config.load
        tick_store  = TickStore.new
        engine     = CoindcxBot::Core::Engine.new(
          config: config,
          logger: build_logger,
          tick_store: tick_store
        )

        symbols    = config.pairs
        panels     = build_panels(tick_store: tick_store, engine: engine, symbols: symbols)
        @render_loop = RenderLoop.new(panels: panels, interval: RENDER_INTERVAL)

        engine_thread = start_engine(engine)

        draw_chrome(symbols)
        @render_loop.start

        keyboard_loop(engine)
      rescue CoindcxBot::Config::ConfigurationError => e
        warn e.message
        warn 'Copy config/bot.yml.example to config/bot.yml'
        exit 1
      rescue Interrupt
        # clean exit
      ensure
        teardown(engine, engine_thread)
      end

      private

      def setup_terminal
        $stdout.sync = true
        $stderr.sync = true
        print TTY::Cursor.hide
        print "\e[2J\e[H"
      end

      def build_logger
        TTY::Logger.new(output: File.open(File::NULL, 'w'))
      end

      def build_panels(tick_store:, engine:, symbols:)
        status = Panels::StatusPanel.new(engine: engine, origin_row: 0)
        ltp    = Panels::LtpPanel.new(
          tick_store: tick_store,
          symbols: symbols,
          origin_row: status.row_count + 1
        )
        [status, ltp]
      end

      def start_engine(engine)
        Thread.new do
          engine.run
        rescue StandardError => e
          warn "[Engine] #{e.class}: #{e.message}"
        end
      end

      def draw_chrome(symbols)
        term_w = TTY::Screen.width || 80
        keybar_row = 3 + 2 + symbols.length + 2

        buf = StringIO.new
        buf << TTY::Cursor.move_to(keybar_row, 0)
        buf << "\e[2m#{'─' * [term_w - 1, 40].min}\e[0m\n"
        buf << keybar_text
        buf << "\n\e[2mAuto-refresh #{(RENDER_INTERVAL * 1000).to_i}ms · ^C or q to exit\e[0m"

        $stdout.print buf.string
        $stdout.flush
      end

      def keybar_text
        keys = [
          ["\e[1mq\e[0m", 'quit'],
          ["\e[1mp\e[0m", 'pause'],
          ["\e[1mr\e[0m", 'resume'],
          ["\e[1mk\e[0m", 'kill on'],
          ["\e[1mo\e[0m", 'kill off'],
          ["\e[1mf\e[0m", 'flatten']
        ]
        keys.map { |k, d| "#{k} \e[2m#{d}\e[0m" }.join("\e[2m  ·  \e[0m")
      end

      def keyboard_loop(engine)
        interactive = stdin_interactive?
        loop do
          if interactive
            ready = IO.select([$stdin], nil, nil, KEYBOARD_POLL)
            break if ready && handle_key($stdin.getc, engine)
          else
            sleep KEYBOARD_POLL
          end
        end
      end

      def handle_key(cmd, engine)
        case cmd
        when 'q', 'Q', "\u0003" then true
        when 'p' then engine.pause!;          false
        when 'r' then engine.resume!;         false
        when 'k' then engine.kill_switch_on!; false
        when 'o' then engine.kill_switch_off!; false
        when 'f' then engine.flatten_all!;    false
        else false
        end
      end

      def stdin_interactive?
        return false if ENV['COINDCX_TUI_POLL_ONLY'] == '1'

        $stdin.tty? && $stdout.tty?
      rescue StandardError
        false
      end

      def teardown(engine, engine_thread)
        @render_loop&.stop
        engine&.request_stop!
        engine_thread&.join(60) if engine_thread&.alive?
        print TTY::Cursor.show
        print "\e[?25h"
      end
    end
  end
end
