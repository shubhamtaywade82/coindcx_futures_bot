# frozen_string_literal: true

require 'bigdecimal'

module CoindcxBot
  module Orderflow
    # Post-strategy filter: annotates or vetoes entry signals using cached Binance liquidity context.
    class LiquidityConfluenceFilter
      def initialize(context_store:, config:, logger:, bus:)
        @store = context_store
        @config = config
        @logger = logger
        @bus = bus
        @emit_last = {} # "pair|rule" => :veto | :confirm | :none
      end

      # @param entry_price [BigDecimal, nil] reference for bps rules (engine passes LTP / last close).
      def filter(signal, entry_price: nil)
        return signal unless %i[open_long open_short].include?(signal.action)

        snap = @store.snapshot(signal.pair.to_s)
        return signal unless context_fresh?(snap)

        entry = entry_price ? BigDecimal(entry_price.to_s) : nil
        return signal if entry.nil? || !entry.positive?

        rules = rules_cfg
        liq = {}
        ctx = snap

        veto_reason = nil
        veto_rule = nil

        if truthy?(rules[:wall_in_path_veto]) && (r = wall_veto(signal, ctx, entry))
          veto_reason = r[:reason].to_s
          veto_rule = :wall_in_path
        elsif truthy?(rules[:iceberg_caution]) && (r = iceberg_veto(signal, ctx, entry))
          veto_reason = r[:reason].to_s
          veto_rule = :iceberg_overhead
        elsif truthy?(rules[:void_caution]) && (r = void_veto(signal, ctx, entry))
          veto_reason = r[:reason].to_s
          veto_rule = r[:rule]
        end

        unless veto_reason
          if truthy?(rules[:sweep_confirms])
            sc = sweep_confirm?(signal, ctx)
            liq[:sweep_confirm] = true if sc
            emit_confirm_transition(signal.pair, :sweep_confirm, active: sc)
          end

          if truthy?(rules[:zone_alignment])
            z = zone_support(signal, ctx, entry)
            liq[:zone_support] = z if z
            emit_confirm_transition(signal.pair, :zone_support, active: !z.nil?)
          end

          if truthy?(rules[:imbalance_alignment]) && ctx[:imbalance]
            warn = imbalance_disagree?(signal, ctx[:imbalance])
            if warn
              liq[:imbalance_warning] = true
              if @config.orderflow_confluence_imbalance_strict?
                emit_veto_transition(signal.pair, :imbalance_disagreement, active: true)
                out = hold_signal(signal, 'imbalance_disagreement', liq)
                log_info(out)
                return out
              end
            end
          end
        end

        if veto_reason
          liq[:veto_rule] = veto_rule if veto_rule
          emit_veto_transition(signal.pair, veto_rule, active: true) if veto_rule
          reset_confirm_emitters(signal.pair)
          out = hold_signal(signal, veto_reason, liq)
          log_info(out)
          return out
        end

        emit_veto_transition(signal.pair, :wall_in_path, active: false)
        emit_veto_transition(signal.pair, :iceberg_overhead, active: false)
        emit_veto_transition(signal.pair, :void_above, active: false)
        emit_veto_transition(signal.pair, :void_below, active: false)
        emit_veto_transition(signal.pair, :imbalance_disagreement, active: false)

        return signal if liq.empty?

        out = open_signal_with_liquidity(signal, liq)
        log_info(out)
        out
      end

      private

      def rules_cfg
        @config.orderflow_confluence_rules
      end

      def context_fresh?(snap)
        return false if snap[:last_touch_ms].nil?

        (now_ms - snap[:last_touch_ms].to_i) <= @config.orderflow_confluence_max_context_age_ms
      end

      def now_ms
        (Time.now.to_f * 1000).to_i
      end

      def truthy?(v)
        v == true || v.to_s == 'true'
      end

      def hold_signal(signal, reason, liq)
        ::CoindcxBot::Strategy::Signal.new(
          action: :hold,
          pair: signal.pair,
          side: nil,
          stop_price: nil,
          reason: reason,
          metadata: merge_liquidity_metadata(signal, liq)
        )
      end

      def open_signal_with_liquidity(signal, liq)
        ::CoindcxBot::Strategy::Signal.new(
          action: signal.action,
          pair: signal.pair,
          side: signal.side,
          stop_price: signal.stop_price,
          reason: signal.reason,
          metadata: merge_liquidity_metadata(signal, liq)
        )
      end

      def merge_liquidity_metadata(signal, liq)
        m = (signal.metadata || {}).dup
        m[:liquidity] = (m[:liquidity] || {}).merge(liq)
        m
      end

      def log_info(signal)
        liq = signal.metadata[:liquidity]
        return if liq.nil? || liq.empty?

        @logger&.info("[liquidity_confluence] #{signal.pair} action=#{signal.action} liquidity=#{liq.inspect}")
      end

      def bps_between(a, b, entry)
        return BigDecimal('999999') unless entry&.positive?

        ((BigDecimal(a.to_s) - BigDecimal(b.to_s)).abs / entry) * BigDecimal('10000')
      end

      def wall_veto(signal, ctx, entry)
        max_bps = BigDecimal(@config.orderflow_confluence_entry_to_wall_bps.to_s)
        min_score = BigDecimal(@config.orderflow_confluence_veto_min_score.to_s)

        case signal.action
        when :open_long
          ctx[:active_walls][:ask].each do |w|
            next unless w[:price] > entry
            next unless bps_between(w[:price], entry, entry) <= max_bps
            next unless w[:score] >= min_score

            return { reason: :wall_in_path }
          end
        when :open_short
          ctx[:active_walls][:bid].each do |w|
            next unless w[:price] < entry
            next unless bps_between(w[:price], entry, entry) <= max_bps
            next unless w[:score] >= min_score

            return { reason: :wall_in_path }
          end
        end
        nil
      end

      def sweep_confirm?(signal, ctx)
        window = @config.orderflow_confluence_sweep_window_ms.to_i
        cut = now_ms - window

        case signal.action
        when :open_long
          ctx[:recent_sweeps].reverse_each do |s|
            next if s[:ts] < cut

            return true if s[:side] == :bid
          end
        when :open_short
          ctx[:recent_sweeps].reverse_each do |s|
            next if s[:ts] < cut

            return true if s[:side] == :ask
          end
        end
        false
      end

      def iceberg_veto(signal, ctx, entry)
        prox = BigDecimal(@config.orderflow_confluence_iceberg_proximity_bps.to_s)

        case signal.action
        when :open_long
          ctx[:recent_icebergs].reverse_each do |ice|
            next unless ice[:side] == :ask
            next unless bps_between(ice[:price], entry, entry) <= prox

            return { reason: :iceberg_overhead }
          end
        when :open_short
          ctx[:recent_icebergs].reverse_each do |ice|
            next unless ice[:side] == :bid
            next unless bps_between(ice[:price], entry, entry) <= prox

            return { reason: :iceberg_overhead }
          end
        end
        nil
      end

      def void_veto(signal, ctx, entry)
        prox = BigDecimal(@config.orderflow_confluence_void_proximity_bps.to_s)

        case signal.action
        when :open_long
          ctx[:voids][:ask].reverse_each do |v|
            lo = [v[:void_start], v[:void_end]].min
            hi = [v[:void_start], v[:void_end]].max
            next unless lo > entry

            edge_bps = [bps_between(lo, entry, entry), bps_between(hi, entry, entry)].min
            next unless edge_bps <= prox

            return { reason: :void_above, rule: :void_above }
          end
        when :open_short
          ctx[:voids][:bid].reverse_each do |v|
            lo = [v[:void_start], v[:void_end]].min
            hi = [v[:void_start], v[:void_end]].max
            next unless hi < entry

            edge_bps = [bps_between(lo, entry, entry), bps_between(hi, entry, entry)].min
            next unless edge_bps <= prox

            return { reason: :void_below, rule: :void_below }
          end
        end
        nil
      end

      def zone_support(signal, ctx, entry)
        dist = BigDecimal(@config.orderflow_confluence_zone_distance_bps.to_s)

        case signal.action
        when :open_long
          ctx[:confirmed_zones][:bid].reverse_each do |z|
            band = z[:price_band]
            next unless band < entry
            next unless bps_between(band, entry, entry) <= dist

            return band
          end
        when :open_short
          ctx[:confirmed_zones][:ask].reverse_each do |z|
            band = z[:price_band]
            next unless band > entry
            next unless bps_between(band, entry, entry) <= dist

            return band
          end
        end
        nil
      end

      def imbalance_disagree?(signal, imbalance)
        bucket = imbalance[:bucket]
        case signal.action
        when :open_long
          bucket == :bearish
        when :open_short
          bucket == :bullish
        else
          false
        end
      end

      def emit_veto_transition(pair, rule, active:)
        return unless rule

        key = "#{pair}|#{rule}"
        if active
          return if @emit_last[key] == :veto

          @emit_last[key] = :veto
          @bus.publish(:'liquidity.confluence.veto', { pair: pair.to_s, rule: rule })
        else
          return if @emit_last[key] != :veto

          @emit_last[key] = :none
        end
      end

      def emit_confirm_transition(pair, rule, active:)
        key = "#{pair}|#{rule}"
        if active
          return if @emit_last[key] == :confirm

          @emit_last[key] = :confirm
          @bus.publish(:'liquidity.confluence.confirm', { pair: pair.to_s, rule: rule })
        else
          @emit_last[key] = :none if @emit_last[key] == :confirm
        end
      end

      def reset_confirm_emitters(pair)
        %i[sweep_confirm zone_support].each do |r|
          @emit_last.delete("#{pair}|#{r}")
        end
      end
    end
  end
end
