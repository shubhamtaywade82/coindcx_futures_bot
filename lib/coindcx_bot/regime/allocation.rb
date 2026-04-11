# frozen_string_literal: true

module CoindcxBot
  module Regime
    # Volatility-rank → coarse tier (1-based vol_rank from HmmEngine).
    module Allocation
      module_function

      def vol_tier(vol_rank, vol_rank_total)
        n = [vol_rank_total.to_i, 2].max
        r = [[vol_rank.to_i, 1].max, n].min
        pos = (r - 1).to_f / (n - 1)
        if pos <= 0.34
          :low_vol
        elsif pos >= 0.66
          :high_vol
        else
          :mid_vol
        end
      end

      def tier_allows_new_entry?(tier, strategy_cfg)
        case tier
        when :high_vol
          !truthy?(strategy_cfg[:block_entries_high_vol])
        else
          true
        end
      end

      def truthy?(v)
        v == true || v.to_s.downcase == 'true' || v.to_s == '1'
      end
    end
  end
end
