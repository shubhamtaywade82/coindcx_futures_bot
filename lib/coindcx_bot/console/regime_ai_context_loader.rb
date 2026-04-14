# frozen_string_literal: true

require 'logger'

module CoindcxBot
  module Console
    # Fetches recent USDT-M perpetual candlesticks from CoinDCX REST for AI console workflows
    # (`Regime::AiBrain`, `SmcSetup::PlannerBrain`, etc.). Shape matches `Engine#build_regime_ai_context`.
    class RegimeAiContextLoader
      class Error < StandardError; end

      DEFAULT_PAIRS = %w[B-SOL_USDT B-BTC_USDT B-ETH_USDT].freeze

      def self.fetch!(
        config:,
        pairs: nil,
        positions: nil,
        md: nil,
        clock: -> { Time.now }
      )
        pairs = Array(pairs || DEFAULT_PAIRS).map(&:to_s).uniq
        md ||= build_market_data_gateway!(config)
        exec_res = config.strategy.fetch(:execution_resolution, '15m').to_s
        htf_res = config.strategy.fetch(:higher_timeframe_resolution, '1h').to_s
        lookback = config.runtime.fetch(:candle_lookback, 120).to_i
        bars_per_pair = config.regime_ai_bars_per_pair
        max_pairs = config.regime_ai_max_pairs
        selected = pairs.first(max_pairs)

        from, to = candle_window(exec_res, lookback, clock.call)
        candles_by_pair = {}
        errors = []

        selected.each do |pair|
          res = md.list_candlesticks(pair: pair, resolution: exec_res, from: from, to: to)
          unless res.ok?
            errors << "#{pair}: #{res.message}"
            next
          end
          rows = Array(res.value).last(bars_per_pair).map do |c|
            { o: c.open, h: c.high, l: c.low, c: c.close, v: c.volume }
          end
          candles_by_pair[pair] = rows
        end

        if candles_by_pair.empty?
          raise Error, "No candlesticks loaded (#{errors.join('; ')})"
        end

        errors.each { |e| warn "[console] skipped: #{e}" } unless errors.empty?

        pos = resolved_positions(config, positions)
        {
          exec_resolution: exec_res,
          htf_resolution: htf_res,
          positions: pos,
          open_count: pos.size,
          pairs: candles_by_pair.keys,
          candles_by_pair: candles_by_pair
        }
      end

      def self.build_market_data_gateway!(config)
        api_key = ENV['COINDCX_API_KEY'].to_s.strip
        secret = ENV['COINDCX_API_SECRET'].to_s.strip
        if api_key.empty? || secret.empty?
          raise Error, 'Set COINDCX_API_KEY and COINDCX_API_SECRET to fetch live candles.'
        end

        CoinDCX.configure do |c|
          c.api_key = api_key
          c.api_secret = secret
          c.logger = Logger.new(File::NULL)
        end
        client = CoinDCX.client
        Gateways::MarketDataGateway.new(
          client: client,
          margin_currency_short_name: config.margin_currency_short_name
        )
      end

      def self.candle_window(resolution, bars, now)
        mult = Core::Engine.resolution_seconds(resolution)
        to = now.to_i
        from = to - (bars * mult)
        [from, to]
      end

      def self.resolved_positions(config, positions)
        journal = nil
        return positions unless positions.nil?

        journal = Persistence::Journal.new(config.journal_path)
        journal.open_positions
      ensure
        journal.close if journal
      end

      private_class_method :build_market_data_gateway!, :candle_window, :resolved_positions
    end
  end
end
