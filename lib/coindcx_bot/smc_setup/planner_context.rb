# frozen_string_literal: true

require_relative '../dto/candle'
require_relative '../smc_confluence/candles'
require_relative '../smc_confluence/engine'
require_relative '../smc_confluence/configuration'
require_relative '../trading_ai/smc_snapshot'
require_relative '../trading_ai/feature_enricher'
require_relative 'state_builder'

module CoindcxBot
  module SmcSetup
    # Builds Ollama planner input: deterministic market_state (+ optional OHLCV features) per pair.
    module PlannerContext
      module_function

      def build(pairs:, candles_by_pair:, open_count:, exec_resolution:, htf_resolution:,
                strategy_cfg:, config:, ltps_by_pair: {})
        smc_cfg = SmcConfluence::Configuration.from_hash((strategy_cfg || {})[:smc_confluence] || {})
        min = config.smc_setup_planner_min_candles
        tail_n = config.smc_setup_planner_ohlcv_tail
        tz = config.smc_setup_planner_tz_offset_minutes
        mult = resolution_seconds(exec_resolution)

        market_state_by_pair = {}
        features_by_pair = {}
        candles_tail_by_pair = {}

        Array(pairs).each do |p|
          raw = candles_by_pair[p] || candles_by_pair[p.to_s]
          dtos = normalize_to_dto_candles(raw, mult: mult)
          candles_tail_by_pair[p] = ohlcv_tail_from_dtos(dtos, tail_n)

          if dtos.size < min
            market_state_by_pair[p] = { pair: p, error: 'insufficient_candles', have: dtos.size, need: min }
            next
          end

          rows = SmcConfluence::Candles.from_dto(dtos)
          bar = SmcConfluence::Engine.run(rows, configuration: smc_cfg).last

          if config.smc_setup_planner_include_market_state? && bar
            market_state_by_pair[p] = StateBuilder.build(
              pair: p,
              bar_result: bar,
              candles: rows,
              timeframe: exec_resolution
            )
          elsif config.smc_setup_planner_include_market_state?
            market_state_by_pair[p] = { pair: p, error: 'no_bar_result' }
          end

          next unless config.smc_setup_planner_include_ohlcv_features? && bar

          smc = CoindcxBot::TradingAi::SmcSnapshot.from_bar_result(bar)
          features_by_pair[p] = CoindcxBot::TradingAi::FeatureEnricher.call(
            candles: rows,
            smc: smc,
            dtw: {},
            history: [],
            entry: nil,
            stop_loss: nil,
            targets: [],
            symbol: p,
            timeframe: exec_resolution,
            tz_offset_minutes: tz
          )
        end

        ltps = Array(pairs).to_h do |p|
          v = ltps_by_pair[p] || ltps_by_pair[p.to_s]
          [p, v ? Float(v).round(8) : nil]
        end

        {
          pairs: Array(pairs),
          candles_by_pair: candles_tail_by_pair,
          market_state_by_pair: market_state_by_pair,
          features_by_pair: features_by_pair,
          ltps_by_pair: ltps,
          open_count: open_count,
          exec_resolution: exec_resolution,
          htf_resolution: htf_resolution
        }
      end

      def resolution_seconds(resolution)
        case resolution.to_s
        when /^(\d+)m$/
          ::Regexp.last_match(1).to_i * 60
        when /^(\d+)h$/
          ::Regexp.last_match(1).to_i * 3600
        when /^(\d+)d$/
          ::Regexp.last_match(1).to_i * 86_400
        else
          900
        end
      end

      def normalize_to_dto_candles(raw, mult:)
        arr = Array(raw)
        return [] if arr.empty?

        if arr.first.respond_to?(:open) && arr.first.respond_to?(:time)
          return arr
        end

        base = Time.now.to_i - (arr.size * mult)
        arr.each_with_index.map do |c, i|
          h = c.respond_to?(:to_h) ? c.to_h : c
          h = h.transform_keys(&:to_sym)
          ts = h[:time] || h[:t] || h[:timestamp]
          time = coerce_candle_time(ts, base: base, index: i, mult: mult)
          CoindcxBot::Dto::Candle.new(
            time: time,
            open: Float(h[:open] || h[:o]),
            high: Float(h[:high] || h[:h]),
            low: Float(h[:low] || h[:l]),
            close: Float(h[:close] || h[:c]),
            volume: Float(h[:volume] || h[:v] || 0)
          )
        end
      end

      def ohlcv_tail_from_dtos(dtos, n)
        Array(dtos).last(n).map do |c|
          {
            o: c.open.to_f,
            h: c.high.to_f,
            l: c.low.to_f,
            c: c.close.to_f,
            v: c.volume.to_f,
            t: c.time.respond_to?(:to_i) ? c.time.to_i : Integer(c.time)
          }
        end
      end

      def coerce_candle_time(ts, base:, index:, mult:)
        case ts
        when Time then ts
        when Integer then Time.at(ts)
        when String
          if ts.match?(/\A\d+\z/)
            Time.at(Integer(ts, 10))
          else
            Time.parse(ts)
          end
        else
          Time.at(base + (index * mult))
        end
      rescue ArgumentError, TypeError
        Time.at(base + (index * mult))
      end
    end
  end
end
