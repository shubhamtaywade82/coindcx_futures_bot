# frozen_string_literal: true

require 'json'
require 'time'

module CoindcxBot
  # Read-only snapshot of the SQLite journal (open positions + today's INR PnL + recent paper fills).
  class PaperStatus
    def self.run(stdout: $stdout)
      journal = nil
      config = Config.load
      journal = Persistence::Journal.new(config.journal_path)
      new(config: config, journal: journal, output: stdout).print
      true
    rescue Config::ConfigurationError => e
      warn e.message
      warn 'Copy config/bot.yml.example to config/bot.yml'
      false
    ensure
      journal&.close
    end

    def initialize(config:, journal:, output: $stdout)
      @config = config
      @journal = journal
      @output = output
    end

    def print
      path = @config.journal_path
      mode = @config.dry_run? ? 'paper (dry_run: true)' : 'live'
      mode = "#{mode} (place_orders: false)" if !@config.dry_run? && !@config.place_orders?

      @output.puts "Journal path: #{path}"
      @output.puts "Config mode:   #{mode}"
      @output.puts "PnL today:     ₹#{@journal.daily_pnl_inr.to_s('F')} (INR, from journal meta)"
      @output.puts ''

      rows = @journal.open_positions
      if rows.empty?
        @output.puts 'Open positions: none'
      else
        @output.puts "Open positions (#{rows.size}):"
        rows.each { |r| @output.puts format_position_line(r) }
      end

      @output.puts ''
      print_recent_paper_realized
    end

    private

    def format_position_line(r)
      id = r[:id]
      opened = r[:opened_at] ? Time.at(Integer(r[:opened_at])).utc.iso8601 : '?'
      "#{id}\t#{r[:pair]}\t#{r[:side]}\tentry=#{r[:entry_price]}\tqty=#{r[:quantity]}\tstop=#{r[:stop_price]}\topened=#{opened}"
    end

    def print_recent_paper_realized
      events = @journal.recent_events(80).select { |e| e['type'] == 'paper_realized' }.first(8)
      if events.empty?
        @output.puts 'Recent paper_realized (event_log): none'
        return
      end

      @output.puts 'Recent paper_realized (event_log):'
      events.each do |e|
        payload = JSON.parse(e['payload'])
        t = Time.at(Integer(e['ts'])).utc.iso8601
        @output.puts "  #{t}  ##{payload['position_id']} #{payload['pair']}  " \
                     "₹#{payload['pnl_inr']}  (#{payload['pnl_usdt']} USDT @ exit #{payload['exit_price']})"
      rescue JSON::ParserError
        @output.puts "  (bad payload) #{e['type']} ts=#{e['ts']}"
      end
    end
  end
end
