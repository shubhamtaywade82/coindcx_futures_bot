# frozen_string_literal: true

require 'pastel'
require 'tty-box'
require 'tty-logger'
require 'tty-screen'
require 'tty-table'

module CoindcxBot
  module Tui
    class App
      REFRESH_SECONDS = 1

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

        sleep 0.75
        quit_ui = false

        begin
          until quit_ui
            print_dashboard(engine, pastel)
            print_keybar(pastel, TTY::Screen.width)
            ready = IO.select([$stdin], nil, nil, REFRESH_SECONDS)
            next unless ready

            cmd = $stdin.getc
            quit_ui = dispatch(engine, cmd)
          end
        rescue Interrupt
          logger.info(pastel.dim('Interrupted — stopping engine…'))
        ensure
          engine.request_stop!
          worker.join(60) if worker&.alive?
        end
      rescue CoindcxBot::Config::ConfigurationError => e
        warn e.message
        warn 'Copy config/bot.yml.example to config/bot.yml'
        exit 1
      end

      private

      def dispatch(engine, cmd)
        case cmd
        when 'q', 'Q', "\u0003"
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
        when '.', ' ', "\r", "\n"
          false
        else
          false
        end
      end

      def print_dashboard(engine, pastel)
        snap = engine.snapshot
        system('clear') || system('cls')

        term_w = TTY::Screen.width
        term_w = 72 if term_w.nil? || term_w < 48
        inner_w = [term_w - 4, 120].min

        body = +''

        body << title_block(pastel, snap)
        body << "\n"
        body << status_strip(pastel, snap)
        body << "\n"
        body << metrics_line(pastel, snap)
        body << "\n"
        body << alerts_block(pastel, snap)
        body << section_title(pastel, 'Markets', inner_w)
        body << markets_table(snap, inner_w)
        body << "\n"
        body << section_title(pastel, 'Journal positions', inner_w)
        body << positions_block(snap, inner_w)

        begin
          framed = TTY::Box.frame(
            width: term_w,
            padding: [0, 1],
            title: { top_left: pastel.bold.cyan(' CoinDCX '), top_right: pastel.dim(' futures ') },
            border: :light,
            style: { border: { fg: :cyan, dim: true } }
          ) { body }
          puts framed
        rescue StandardError
          puts body
        end
        $stdout.flush
      end

      def title_block(pastel, snap)
        mode =
          if snap.dry_run
            pastel.inverse.magenta.bold('  DRY RUN — no live orders  ')
          else
            pastel.inverse.red.bold('  LIVE — real orders  ')
          end
        sub = pastel.dim("Auto-refresh #{REFRESH_SECONDS}s · local #{Time.now.strftime('%Y-%m-%d %H:%M:%S')}")
        "#{mode}\n#{sub}"
      end

      def visible_length(str)
        str.gsub(/\e\[[0-9;]*m/, '').length
      end

      def status_strip(pastel, snap)
        parts = []
        parts << if snap.running
                   pastel.green('●') + pastel.bold(' Engine ')
                 else
                   pastel.red('●') + pastel.bold(' Stopped ')
                 end

        parts << if snap.paused
                   pastel.on_yellow.black(' PAUSED ')
                 else
                   pastel.dim(' run ')
                 end

        parts << if snap.kill_switch
                   pastel.on_red.white(' KILL ')
                 else
                   pastel.dim(' kill·off ')
                 end

        stale_sec = snap.stale_tick_seconds || 45
        parts << if snap.stale
                   pastel.on_yellow.black(" STALE (>#{stale_sec}s) ")
                 else
                   pastel.green(' feed·ok ')
                 end

        parts.join(pastel.dim(' │ '))
      end

      def metrics_line(pastel, snap)
        pnl = format_inr(pastel, snap.daily_pnl)
        err =
          if snap.last_error.nil?
            pastel.dim('none')
          else
            pastel.red(snap.last_error.inspect)
          end
        "#{pastel.bold('PnL today')} #{pnl}  #{pastel.dim('·')}  #{pastel.bold('last_error')} #{err}"
      end

      def format_inr(pastel, value)
        pastel.bold.cyan("₹#{value.to_s('F')}")
      end

      def alerts_block(pastel, snap)
        lines = []
        if snap.dry_run
          lines << pastel.dim('Orders are simulated — set runtime.dry_run: false in config/bot.yml only when ready.')
        end
        lines << pastel.yellow('Paused: strategy will not open new positions.') if snap.paused
        lines << pastel.red('Kill switch: new entries blocked.') if snap.kill_switch
        if snap.stale
          sec = snap.stale_tick_seconds || 45
          lines << pastel.yellow(
            "WebSocket ticks older than #{sec}s — new entries blocked; candles still refresh. " \
            'Check network or increase runtime.stale_tick_seconds if the feed is normally slower.'
          )
        end
        if snap.pairs.any? { |p| (snap.ticks[p] || {})[:price].nil? } && snap.last_error.nil?
          lines << pastel.yellow('Waiting for first WS price — verify API keys and pair codes in config/bot.yml.')
        end
        return '' if lines.empty?

        lines.join("\n") + "\n"
      end

      def section_title(pastel, title, _width)
        "\n#{pastel.cyan.bold("  #{title}")}\n#{pastel.dim("  #{'─' * [title.length + 2, 24].max}")}\n"
      end

      def markets_table(snap, width)
        now = Time.now
        header = %w[Pair LTP Last\ tick Age]
        rows = snap.pairs.map do |p|
          tick = snap.ticks[p] || {}
          price = tick[:price]
          at = tick[:at]
          age_s =
            if at.is_a?(Time)
              sec = (now - at).clamp(0, 86_400)
              format('%.1fs', sec)
            else
              '—'
            end
          tick_str =
            if at.is_a?(Time)
              at.strftime('%H:%M:%S')
            else
              '—'
            end
          ltp = price ? price.to_s('F') : '—'
          [p, ltp, tick_str, age_s]
        end

        col_w = column_widths_for(width, header, rows)
        table = TTY::Table.new(header, rows, column_widths: col_w)
        table.render(:unicode, multiline: true, width: width)
      end

      def column_widths_for(width, header, rows)
        usable = [width - 8, 40].max
        pairs_max = rows.map { |r| r[0].to_s.length }.max
        target = [(usable * 0.42).to_i, [pairs_max, header[0].length].max + 1].max
        pair_col = [[target, 12].max, 28].min
        remaining = [usable - pair_col - 2, 24].max
        ltp_col = [[(remaining * 0.30).to_i, 10].max, 16].min
        time_col = [[(remaining * 0.40).to_i, 10].max, 14].min
        age_col = [remaining - ltp_col - time_col, 6].max
        [pair_col, ltp_col, time_col, age_col]
      end

      def positions_block(snap, width)
        return pastel.dim("  (none)\n") if snap.positions.empty?

        header = %w[ID Pair Side Qty Entry Stop P]
        rows = snap.positions.map do |r|
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
        col_w = [6, 14, 6, 10, 10, 10, 4]
        table = TTY::Table.new(header, rows, column_widths: col_w)
        table.render(:unicode, multiline: true, width: width)
      end

      def print_keybar(pastel, term_w)
        w = term_w || 80
        keys = [
          [pastel.bold('q'), 'quit'],
          [pastel.bold('p'), 'pause'],
          [pastel.bold('r'), 'resume'],
          [pastel.bold('k'), 'kill on'],
          [pastel.bold('o'), 'kill off'],
          [pastel.bold('f'), 'flatten'],
          [pastel.bold('.'), 'refresh'],
          [pastel.bold('space'), 'refresh']
        ]
        line = keys.map { |k, d| "#{k} #{pastel.dim(d)}" }.join(pastel.dim('  ·  '))
        if visible_length(line) > w - 2
          line = keys.each_slice(4).map { |slice| slice.map { |k, d| "#{k} #{pastel.dim(d)}" }.join('  ') }.join("\n")
        end
        puts
        puts pastel.dim('─' * [w - 1, 40].min)
        puts line
        puts pastel.dim("Auto-refresh #{REFRESH_SECONDS}s · ^C or q to exit")
      end
    end
  end
end
