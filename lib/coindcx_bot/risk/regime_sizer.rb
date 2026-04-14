# frozen_string_literal: true

require 'bigdecimal'

module CoindcxBot
  module Risk
    # Optional size multiplier from daily loss vs reference capital (INR), independent of HMM.
    class RegimeSizer
      def initialize(config)
        @cfg = config.regime_risk_section
        @capital = config.capital_inr || BigDecimal('100000')
      end

      def multiplier_for(journal)
        return BigDecimal('1') unless enabled?

        cap = @capital
        return BigDecimal('1') unless cap&.positive?

        daily = journal.daily_pnl_inr
        loss_pct = -daily / cap * 100
        halt_at = BigDecimal(@cfg.fetch(:daily_dd_halt_pct_of_capital, 3).to_s)
        reduce_at = BigDecimal(@cfg.fetch(:daily_dd_reduce_pct_of_capital, 2).to_s)

        if loss_pct >= halt_at
          BigDecimal('0')
        elsif loss_pct >= reduce_at
          BigDecimal(@cfg.fetch(:size_reduce_factor, 0.5).to_s)
        else
          BigDecimal('1')
        end
      end

      private

      def enabled?
        @cfg[:enabled] == true || @cfg[:enabled].to_s.downcase == 'true' || @cfg[:enabled].to_s == '1'
      end
    end
  end
end
