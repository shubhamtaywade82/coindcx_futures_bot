# frozen_string_literal: true

require 'logger'
require 'tty-spinner'

module CoindcxBot
  module Doctor
    module_function

    PAIR_KEYS = %i[
      pair instrument symbol market ticker contract_code product_id
      underlying pair_name instrument_name short_name name
      instrument_pair display_name
    ].freeze

    ARRAY_KEYS = %w[instruments data pairs active_instruments markets results items list].freeze

    # Highlight only native SOL / ETH USDT perps (avoids B-SOLV_USDT, B-ETHFI_USDT, etc.).
    CORE_SOL_ETH_PAIRS = %w[B-SOL_USDT B-ETH_USDT].freeze

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
      stdout.puts "Active USDT-margin instruments: #{rows.size} (highlight: #{CORE_SOL_ETH_PAIRS.join(', ')})"
      matches = rows.select { |r| match_sol_eth?(r) }
      if matches.empty?
        stdout.puts "No #{CORE_SOL_ETH_PAIRS.join(' / ')} in list — inspect sample rows below."
      end
      sample = matches.empty? ? rows.first(30) : matches
      sample.each { |r| stdout.puts format_row(r) }
      stdout.puts "\nCopy exact `pair` values into config/bot.yml under `pairs:`."
      true
    end

    def match_sol_eth?(row)
      p = pair_from_row(row).to_s.strip.upcase
      CORE_SOL_ETH_PAIRS.include?(p)
    end

    def normalize_instruments(value)
      extract_list(value).map { |el| normalize_element(el) }
    end

    def normalize_element(el)
      case el
      when String
        { pair: el.strip }
      when Hash
        CoinDCX::Utils::Payload.symbolize_keys(el)
      else
        {}
      end
    end

    def extract_list(value)
      case value
      when nil
        []
      when Array
        return [] if value.empty?

        first = value.first
        if first.is_a?(Hash) || first.is_a?(String)
          value
        elsif first.is_a?(Array)
          value.flat_map { |x| extract_list(x) }
        else
          value.filter_map { |x| x if x.is_a?(Hash) || x.is_a?(String) }
        end
      when Hash
        ARRAY_KEYS.each do |key|
          sym = key.to_sym
          next unless value.key?(sym) || value.key?(key)

          inner = value[sym] || value[key]
          got = extract_list(inner)
          return got if got.any?
        end
        return [value] if value.key?(:pair) || value.key?('pair')

        if value.all? { |k, v| (k.is_a?(String) || k.is_a?(Symbol)) && v.is_a?(Hash) }
          return value.map { |k, meta| CoinDCX::Utils::Payload.symbolize_keys(meta).merge(pair: k.to_s) }
        end

        value.values.flat_map do |v|
          case v
          when Array, Hash
            extract_list(v)
          else
            []
          end
        end
      else
        []
      end
    end

    def pair_from_row(row)
      case row
      when String
        row.strip
      when Hash
        PAIR_KEYS.each do |k|
          v = row[k]
          next if v.nil?

          s = v.to_s.strip
          return s unless s.empty?
        end
        row.each_value do |v|
          s = v.to_s.strip
          next if s.empty?

          return s if s.match?(/\A[A-Z]\-[A-Z0-9_.]+\z/i)
        end
        row.values.find { |v| v.is_a?(String) && v.match?(/_USDT|_INR|FUTURES|PERP/i) }&.to_s&.strip || '?'
      else
        '?'
      end
    end

    def format_row(row)
      pair = pair_from_row(row)
      return pair if row.is_a?(String)

      extras =
        if row.is_a?(Hash)
          row
            .reject { |k, _| PAIR_KEYS.include?(k) }
            .first(4)
            .map { |k, v| "#{k}=#{v}" }
            .join(' ')
        else
          ''
        end
      extras.empty? ? pair : "#{pair}  #{extras}"
    end
  end
end
