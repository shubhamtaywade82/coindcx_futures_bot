# frozen_string_literal: true

RSpec.describe CoindcxBot::TradingAi::SmcSnapshot do
  describe '.from_bar_result' do
    it 'returns an empty hash when bar is nil' do
      expect(described_class.from_bar_result(nil)).to eq({})
    end

    it 'maps structure bias and sweep flags into a flat snapshot' do
      bar = CoindcxBot::SmcConfluence::BarResult.new(
        bar_index: 10,
        bos_bull: true,
        bos_bear: false,
        choch_bull: false,
        choch_bear: false,
        structure_bias: 1,
        in_bull_ob: true,
        in_bear_ob: false,
        bull_ob_valid: true,
        bear_ob_valid: false,
        bull_ob_lo: 1.0,
        bear_ob_hi: 2.0,
        recent_bull_sweep: false,
        recent_bear_sweep: false,
        liq_sweep_bull: true,
        liq_sweep_bear: false,
        ms_trend: 1,
        tl_bear_break: false,
        tl_bull_break: false,
        tl_bear_retest: false,
        tl_bull_retest: false,
        sess_level_bull: false,
        sess_level_bear: false,
        vp_bull_conf: false,
        vp_bear_conf: false,
        near_poc: true,
        near_vah: false,
        near_val: false,
        long_score: 3,
        short_score: 1,
        long_signal: false,
        short_signal: false,
        pdh_sweep: false,
        pdl_sweep: false,
        pdh: nil,
        pdl: nil,
        poc: nil,
        vah: nil,
        val_line: nil,
        atr14: 1.5,
        fvg_bull_align: true,
        fvg_bear_align: false,
        in_discount: false,
        in_premium: true
      )

      h = described_class.from_bar_result(bar)
      expect(h[:htf_bias]).to eq('bull')
      expect(h[:bos]).to be(true)
      expect(h[:choch]).to be(false)
      expect(h[:bull_ob]).to be(true)
      expect(h[:liq_sweep]).to eq('bullish')
      expect(h[:vp_context]).to eq('near_poc')
    end
  end
end
