# frozen_string_literal: true

require 'logger'
require 'tty-spinner'

module CoindcxBot
  module Doctor
    module_function

    def run(stdout: $stdout)
      api_key = ENV['COINDCX_API_KEY']
      secret = ENV['COINDCX_API_SECRET']
      unless api_key && secret
        stdout.puts 'Missing COINDCX_API_KEY or COINDCX_API_SECRET in environment.'
        return false
      end

      CoinDCX.configure do |c|
        c.api_key = api_key
        c.api_secret = secret
        c.logger = Logger.new(File::NULL)
      end

      client = CoinDCX.client
      md = CoindcxBot::Gateways::MarketDataGateway.new(client: client, margin_currency_short_name: 'USDT')
      spinner = TTY::Spinner.new(':spinner :title', hide_cursor: true)
      spinner.update(title: 'Fetching instruments…')
      spinner.auto_spin
      res =
        begin
          md.list_active_instruments(margin_currency_short_names: ['USDT'])
        ensure
          spinner.stop
        end
      unless res.ok?
        stdout.puts "REST failed: #{res.code} #{res.message}"
        return false
      end

      rows = normalize_instruments(res.value)
      stdout.puts "Active USDT-margin instruments: #{rows.size} (showing SOL/ETH matches)"
      matches = rows.select { |r| match_sol_eth?(r) }
      if matches.empty?
        stdout.puts 'No rows matched "SOL" or "ETH" in raw payload — inspect full list below.'
      end
      (matches.empty? ? rows.first(30) : matches).each { |r| stdout.puts format_row(r) }
      stdout.puts "\nCopy exact `pair` values into config/bot.yml under `pairs:`."
      true
    end

    def match_sol_eth?(row)
      s = row.values.join(' ').upcase
      s.include?('SOL') || s.include?('ETH')
    end

    def normalize_instruments(value)
      list =
        case value
        when Array then value
        when Hash
          value[:instruments] || value['instruments'] || value[:data] || value.values.find { |v| v.is_a?(Array) } || []
        else
          []
        end
      Array(list).map { |h| h.is_a?(Hash) ? h.transform_keys(&:to_sym) : {} }
    end

    def format_row(row)
      pair = row[:pair] || row[:instrument] || row[:symbol] || '?'
      name = row[:name] || row[:short_name] || ''
      "#{pair}  #{name}"
    end
  end
end
