# frozen_string_literal: true

require_relative 'signal'
require_relative 'trend_continuation'
require_relative 'supertrend_profit'
require_relative 'smc_confluence'

module CoindcxBot
  module Strategy
    # Priority-based multi-strategy: first child that emits +:open_long+ / +:open_short+ wins.
    # Open positions delegate exits to the child recorded in +entry_lane+ (journal), or the first
    # child when legacy rows have no lane. Cooldown is stored in journal meta (no sleep in tick).
    class MetaFirstWin
      COOLDOWN_META_PREFIX = 'meta_first_win:cooldown_until:'

      class << self
        def cooldown_meta_key(pair)
          "#{COOLDOWN_META_PREFIX}#{pair}"
        end

        def record_entry_cooldown(journal:, config:, pair:)
          sec = config.meta_first_win_cooldown_seconds_after_close
          return if sec <= 0
          return unless config.meta_first_win_strategy?

          journal.meta_set(cooldown_meta_key(pair.to_s), (Time.now.to_f + sec).to_s)
        end
      end

      def initialize(strategy_config, journal:)
        @cfg = strategy_config.transform_keys(&:to_sym)
        @journal = journal
        @meta = (@cfg[:meta_first_win].is_a?(Hash) ? @cfg[:meta_first_win] : {}).transform_keys(&:to_sym)
        @children = build_children!
      end

      def evaluate(pair:, candles_htf:, candles_exec:, position:, ltp:, regime_hint: nil)
        if cooling_down?(pair)
          return hold(pair, 'meta_cooldown')
        end

        if position
          delegate_to_owner(pair, candles_htf, candles_exec, position, ltp, regime_hint)
        else
          scan_for_entry(pair, candles_htf, candles_exec, position, ltp, regime_hint)
        end
      end

      private

      def cooling_down?(pair)
        sec = meta_cooldown_seconds
        return false if sec <= 0

        raw = @journal.meta_get(self.class.cooldown_meta_key(pair))
        return false if blank?(raw)

        Time.now.to_f < Float(raw)
      rescue ArgumentError, TypeError
        false
      end

      def meta_cooldown_seconds
        v = @meta[:cooldown_seconds_after_close]
        return 0 if v.nil?

        Float(v.to_s)
      rescue ArgumentError, TypeError
        0
      end

      def build_children!
        list = Array(@meta[:children])
        raise CoindcxBot::Config::ConfigurationError, 'meta_first_win.children must be a non-empty array' if list.empty?

        list.each_with_index.map do |raw, idx|
          h = raw.is_a?(Hash) ? raw.transform_keys(&:to_sym) : {}
          lane = (h[:name] || h[:lane]).to_s.strip
          raise CoindcxBot::Config::ConfigurationError, 'each meta_first_win child needs name:' if lane.empty?

          merged = merged_child_config(h)
          strat = instantiate_child(merged)
          { lane: lane, strat: strat, priority: idx }
        end
      end

      def merged_child_config(child_hash)
        lane = (child_hash[:name] || child_hash[:lane]).to_s.strip
        base = @cfg.except(:meta_first_win, :children, :name)
        base.merge(child_hash.merge(name: lane))
      end

      def instantiate_child(merged)
        n = (merged[:name] || 'trend_continuation').to_s
        case n
        when 'meta_first_win'
          raise CoindcxBot::Config::ConfigurationError, 'meta_first_win cannot nest meta_first_win'
        when 'regime_vol_tier'
          raise CoindcxBot::Config::ConfigurationError,
                'meta_first_win children must be leaf strategies (trend_continuation, supertrend_profit, smc_confluence) in this version'
        when 'trend_continuation'
          TrendContinuation.new(merged)
        when 'supertrend_profit'
          SupertrendProfit.new(merged)
        when 'smc_confluence'
          SmcConfluence.new(merged)
        else
          raise CoindcxBot::Config::ConfigurationError, "unsupported meta_first_win child: #{n.inspect}"
        end
      end

      def scan_for_entry(pair, candles_htf, candles_exec, position, ltp, regime_hint)
        @children.each do |rec|
          sig = rec[:strat].evaluate(
            pair: pair,
            candles_htf: candles_htf,
            candles_exec: candles_exec,
            position: position,
            ltp: ltp,
            regime_hint: regime_hint
          )
          next unless entry_action?(sig)

          meta = (sig.metadata || {}).transform_keys(&:to_sym).merge(
            meta_lane: rec[:lane],
            meta_priority: rec[:priority]
          )
          return Signal.new(
            action: sig.action,
            pair: sig.pair,
            side: sig.side,
            stop_price: sig.stop_price,
            reason: "meta_first_win(#{sig.reason})",
            metadata: meta
          )
        end
        hold(pair, 'meta_no_child_entry')
      end

      def delegate_to_owner(pair, candles_htf, candles_exec, position, ltp, regime_hint)
        lane = position[:entry_lane].to_s.strip
        lane = @children.first[:lane] if lane.empty?

        rec = @children.find { |c| c[:lane] == lane } || @children.first
        rec[:strat].evaluate(
          pair: pair,
          candles_htf: candles_htf,
          candles_exec: candles_exec,
          position: position,
          ltp: ltp,
          regime_hint: regime_hint
        )
      end

      def entry_action?(sig)
        %i[open_long open_short].include?(sig.action)
      end

      def hold(pair, reason)
        Signal.new(action: :hold, pair: pair, side: nil, stop_price: nil, reason: reason, metadata: {})
      end

      def blank?(v)
        v.nil? || v.to_s.strip.empty?
      end
    end
  end
end
