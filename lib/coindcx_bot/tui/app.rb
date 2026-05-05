# frozen_string_literal: true

require 'fileutils'
require 'io/console'
require 'tty-cursor'
require 'tty-logger'
require 'tty-screen'

require_relative 'engine_log_filter'
require_relative 'theme'
require_relative 'term_width'
require_relative 'term_height'
require_relative 'ansi_string'

module CoindcxBot
  module Tui
    class App
      include Theme
      RENDER_INTERVAL = 0.25
      KEYBOARD_POLL   = 1
      MIN_TUI_COLS    = 100
      MIN_TUI_ROWS    = 28

      def self.start
        new.run
      end

      # Strips leading slashes so `/focus 1` and `focus 1` both work.
      def self.normalize_palette_command(buf)
        buf.to_s.strip.downcase.sub(%r{\A/+}, '').strip
      end

      def initialize
        @cmd_mode = false
        @cmd_buf = +''
        @cmd_feedback = nil
        @focus = nil
        @stdin_raw_mode = false
      end

      def run
        engine = nil
        engine_thread = nil
        config = CoindcxBot::Config.load
        setup_terminal
        tick_store = TickStore.new
        order_book_store = OrderBookStore.new
        @render_loop = nil
        @ltp_poller = nil
        @tui_footer_poll_interval = nil
        @focus = FocusRing.new(config.pairs)
        engine = CoindcxBot::Core::Engine.new(
          config: config,
          logger: build_logger,
          tick_store: tick_store,
          order_book_store: order_book_store,
          on_tick: ->(_tick) { @render_loop&.request_redraw },
          on_market_data: -> { @render_loop&.request_redraw }
        )

        symbols = config.pairs
        panels  = build_panels(
          tick_store: tick_store,
          order_book_store: order_book_store,
          engine: engine,
          symbols: symbols
        )
        @render_loop = RenderLoop.new(
          panels: panels,
          interval: RENDER_INTERVAL,
          engine: engine,
          focus_sync_proc: -> { @focus&.current }
        )
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
        validate_terminal_size!
        $stdout.sync = true
        $stderr.sync = true
        redirect_stderr_for_tui!
        enable_stdin_raw_if_interactive!
        print TTY::Cursor.hide
        print "\e[2J\e[H"
      end

      def validate_terminal_size!
        cols = TTY::Screen.width
        rows = TTY::Screen.height
        cols = cols.to_i if cols
        rows = rows.to_i if rows
        return if cols.nil? || rows.nil?
        return if cols >= MIN_TUI_COLS && rows >= MIN_TUI_ROWS

        warn "CoinDCX TUI: terminal too small (#{cols}x#{rows}); need >= #{MIN_TUI_COLS}x#{MIN_TUI_ROWS}."
        exit 1
      end

      # Never write engine / gem logs to the real terminal while the TUI redraws on stdout — concurrent
      # writes corrupt the screen (split escape codes and columns). Quiet: discard. Verbose: append to a file.
      def redirect_stderr_for_tui!
        @stderr_backup = $stderr.dup
        target =
          if tui_verbose?
            path = tui_engine_log_path
            FileUtils.mkdir_p(File.dirname(path))
            maybe_rotate_engine_log(path)
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
        inner = TTY::Logger.new(output: out)
        return inner unless tui_verbose?

        EngineLogFilter.new(inner)
      end

      # Set COINDCX_TUI_LOG_MAX_MB (e.g. 128) to rotate an oversized log once at TUI startup (path -> path.1).
      def maybe_rotate_engine_log(path)
        max_mb = ENV['COINDCX_TUI_LOG_MAX_MB'].to_s.to_f
        return if max_mb <= 0
        return unless File.file?(path)

        limit = (max_mb * 1024 * 1024).to_i
        return if File.size(path) < limit

        rotated = "#{path}.1"
        FileUtils.rm_f(rotated)
        File.rename(path, rotated)
      rescue StandardError
        nil
      end
      def build_panels(tick_store:, order_book_store:, engine:, symbols:)
        origin = 0

        header = Panels::HeaderPanel.new(
          engine: engine,
          origin_row: origin,
          focus_pair_proc: -> { @focus&.current }
        )
        origin += header.row_count

        regime_strip = Panels::RegimeStripPanel.new(engine: engine, origin_row: origin)
        origin += regime_strip.row_count

        smc_strip = Panels::SmcSetupStripPanel.new(engine: engine, origin_row: origin)
        origin += smc_strip.row_count

        orderflow = Panels::OrderflowPanel.new(
          bus: engine.instance_variable_get(:@bus),
          origin_row: origin,
          focus_pair_proc: -> { @focus&.current }
        )
        origin += orderflow.row_count

        # Flexible height calculation
        # Keybar is 5 rows (rule + 2 control lines + footer hint + command palette).
        keybar_rows = 5
        fixed_height = origin + keybar_rows + 1 # +1 buffer
        total_h = TermHeight.rows
        avail_h = total_h - fixed_height
        # Grid inner height = avail_h - 4 (top border, header row, mid rule, bot border)
        flex_inner = [avail_h - 4, 6].max

        grid = Panels::DeskFuturesGridPanel.new(
          engine: engine,
          tick_store: tick_store,
          order_book_store: order_book_store,
          symbols: symbols,
          focus_pair_proc: -> { @focus&.current },
          origin_row: origin,
          flexible_height: flex_inner
        )
        origin += grid.row_count

        keybar = Panels::KeybarPanel.new(
          origin_row: origin,
          footer_text_proc: -> { footer_hint_text },
          command_line_proc: -> { command_palette_line }
        )
        [header, regime_strip, smc_strip, orderflow, grid, keybar]
      end

      def start_engine(engine)
        Thread.new do
          Thread.current.report_on_exception = false
          engine.run
        rescue StandardError => e
          msg = "#{e.class}: #{e.message}"
          warn "[Engine] #{msg}"
          engine.engine_loop_failed!(msg)
          @render_loop&.request_redraw
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
        "#{poll_part}WS tick wake · max #{(RENDER_INTERVAL * 1000).to_i}ms if idle · " \
          'q quit · p r k o f · n focus · / cmd · Esc cancel cmd'
      end

      # Dedicated palette row (always visible) — input after `/`, last result otherwise.
      def command_palette_line
        prompt = "#{bold('>')}\e[0m "
        if @cmd_mode
          "#{prompt}#{@cmd_buf}\e[0m"
        else
          fb = @cmd_feedback&.to_s&.strip
          if fb && !fb.empty?
            "#{prompt}\e[33m#{fb}\e[0m"
          else
            "#{prompt}#{dim('type a command (/ optional) · help · pause · flatten · /focus 0')}"
          end
        end
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
        if @cmd_mode
          case cmd
          when "\u0003" then return true
          when "\r", "\n" then run_command_buffer(engine); return false
          when "\e" then @cmd_mode = false; @cmd_buf.clear; @render_loop&.request_redraw; return false
          when "\x7f", "\b" then @cmd_buf.chop!; @render_loop&.request_redraw; return false
          else
            if printable_cmd_char?(cmd)
              @cmd_buf << cmd
              @render_loop&.request_redraw
            end
            return false
          end
        end

        case cmd
        when 'q', 'Q', "\u0003" then true
        when '/' then @cmd_mode = true; @cmd_buf.clear; @cmd_feedback = nil; @render_loop&.request_redraw; false
        when 'n' then @focus&.advance!; @render_loop&.request_redraw; false
        when 'p' then engine.pause!;          false
        when 'r' then engine.resume!;         false
        when 'k' then engine.kill_switch_on!; false
        when 'o' then engine.kill_switch_off!; false
        when 'f' then engine.flatten_all!;    false
        else false
        end
      end

      def printable_cmd_char?(c)
        return false if c.nil? || !c.is_a?(String)

        o = c.ord
        o >= 32 && o < 127
      end

      def run_command_buffer(engine)
        raw = self.class.normalize_palette_command(@cmd_buf)
        @cmd_buf.clear
        @cmd_mode = false
        case raw
        when '', '/'
          @cmd_feedback = nil
        when 'pause', 'p' then engine.pause!; @cmd_feedback = 'paused'
        when 'resume', 'r' then engine.resume!; @cmd_feedback = 'resumed'
        when 'kill' then engine.kill_switch_on!; @cmd_feedback = 'kill on'
        when 'kill off', 'killoff', 'kill-off' then engine.kill_switch_off!; @cmd_feedback = 'kill off'
        when 'flatten', 'flat', 'f' then engine.flatten_all!; @cmd_feedback = 'flatten sent'
        when 'help', 'h', '?'
          @cmd_feedback = 'pause resume kill kill-off flatten focus 0 n (optional leading /)'
        when /\Afocus\s+(\d+)\z/
          @focus&.select_absolute!(Regexp.last_match(1))
          @cmd_feedback = "focus #{Regexp.last_match(1)}"
        when 'n', 'next'
          @focus&.advance!
          @cmd_feedback = 'focus next'
        else
          @cmd_feedback = "unknown: #{raw[0, 28]}"
        end
        @render_loop&.request_redraw
      end

      # bold() and dim() are provided by `include Theme`

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
        disable_stdin_raw!
        print TTY::Cursor.show
      end

      # Canonical (cooked) tty input is line-buffered: getc sees nothing until Enter. Raw mode delivers
      # each byte immediately so the command palette can echo while typing.
      def enable_stdin_raw_if_interactive!
        return unless stdin_interactive?
        return unless $stdin.respond_to?(:raw!)

        $stdin.raw!(intr: true)
        @stdin_raw_mode = true
      rescue StandardError
        @stdin_raw_mode = false
      end

      def disable_stdin_raw!
        return unless @stdin_raw_mode
        return unless $stdin.respond_to?(:cooked!)

        $stdin.cooked!
        @stdin_raw_mode = false
      rescue StandardError
        @stdin_raw_mode = false
      end
    end
  end
end
