# frozen_string_literal: true

require 'fileutils'
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
        engine = nil
        engine_thread = nil
        config = CoindcxBot::Config.load
        setup_terminal
        tick_store = TickStore.new
        @render_loop = nil
        @ltp_poller = nil
        @tui_footer_poll_interval = nil
        engine = CoindcxBot::Core::Engine.new(
          config: config,
          logger: build_logger,
          tick_store: tick_store,
          on_tick: ->(_tick) { @render_loop&.request_redraw }
        )

        symbols = config.pairs
        panels  = build_panels(tick_store: tick_store, engine: engine, symbols: symbols)
        @render_loop = RenderLoop.new(panels: panels, interval: RENDER_INTERVAL)
        start_ltp_rest_poller(config: config, symbols: symbols, tick_store: tick_store)

        engine_thread = start_engine(engine)

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
        redirect_stderr_for_tui!
        print TTY::Cursor.hide
        print "\e[2J\e[H"
      end

      # Never write engine / gem logs to the real terminal while the TUI redraws on stdout — concurrent
      # writes corrupt the screen (split escape codes and columns). Quiet: discard. Verbose: append to a file.
      def redirect_stderr_for_tui!
        @stderr_backup = $stderr.dup
        target =
          if tui_verbose?
            path = tui_engine_log_path
            FileUtils.mkdir_p(File.dirname(path))
            path
          else
            File::NULL
          end
        $stderr.reopen(target, 'a')
        $stderr.sync = true
      rescue StandardError
        $stderr.reopen(File::NULL, 'w')
        $stderr.sync = true
      end

      def tui_engine_log_path
        custom = ENV['COINDCX_TUI_LOG'].to_s.strip
        return File.expand_path(custom) unless custom.empty?

        File.expand_path('tmp/coindcx_tui.log')
      end

      def restore_stderr!
        return unless @stderr_backup

        $stderr.reopen(@stderr_backup)
        @stderr_backup.close
        @stderr_backup = nil
      end

      def tui_verbose?
        ENV['COINDCX_TUI_VERBOSE'].to_s == '1'
      end

      def build_logger
        out =
          if tui_verbose?
            $stderr
          else
            @null_log_io ||= File.open(File::NULL, 'w')
          end
        TTY::Logger.new(output: out)
      end

      def build_panels(tick_store:, engine:, symbols:)
        stale_sec = engine.config.runtime.fetch(:stale_tick_seconds, 45).to_i
        origin = 0

        header = Panels::HeaderPanel.new(engine: engine, origin_row: origin)
        origin += header.row_count

        tri = Panels::TriColumnPanel.new(engine: engine, symbols: symbols, origin_row: origin)
        origin += tri.row_count

        ltp = Panels::LtpPanel.new(
          tick_store: tick_store,
          symbols: symbols,
          origin_row: origin,
          stale_tick_seconds: stale_sec,
          engine: engine
        )
        origin += ltp.row_count

        logs = Panels::EventLogPanel.new(engine: engine, origin_row: origin, max_lines: 6)
        origin += logs.row_count

        keybar = Panels::KeybarPanel.new(origin_row: origin, footer_text_proc: -> { footer_hint_text })
        [header, tri, ltp, logs, keybar]
      end

      def start_engine(engine)
        Thread.new do
          Thread.current.report_on_exception = false
          engine.run
        rescue StandardError => e
          warn "[Engine] #{e.class}: #{e.message}"
        end
      end

      def start_ltp_rest_poller(config:, symbols:, tick_store:)
        interval = tui_ltp_poll_interval_seconds(config)
        @tui_footer_poll_interval = interval.positive? ? interval : nil
        return unless interval.positive?

        md = CoindcxBot::Gateways::MarketDataGateway.new(
          client: CoinDCX.client,
          margin_currency_short_name: config.margin_currency_short_name
        )
        @ltp_poller = LtpRestPoller.new(
          market_data: md,
          pairs: symbols,
          tick_store: tick_store,
          render_loop: @render_loop,
          interval_seconds: interval,
          logger: build_logger
        )
        @ltp_poller.start
      end

      def tui_ltp_poll_interval_seconds(config)
        if ENV.key?('COINDCX_TUI_LTP_POLL_SECONDS')
          ENV['COINDCX_TUI_LTP_POLL_SECONDS'].to_s.strip.to_f
        else
          config.runtime.fetch(:tui_ltp_poll_seconds, 0.5).to_f
        end
      end

      def footer_hint_text
        poll_part =
          if @tui_footer_poll_interval
            "REST LTP ~#{@tui_footer_poll_interval}s · "
          else
            ''
          end
        "#{poll_part}WS tick wake · max #{(RENDER_INTERVAL * 1000).to_i}ms if idle · ^C or q to exit"
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
        @ltp_poller&.stop
        @render_loop&.stop
        engine&.request_stop!
        engine_thread&.join(60) if engine_thread&.alive?
        @null_log_io&.close
        @null_log_io = nil
        restore_stderr!
        print TTY::Cursor.show
        print "\e[?25h"
      end
    end
  end
end
