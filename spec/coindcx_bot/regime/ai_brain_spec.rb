# frozen_string_literal: true

RSpec.describe CoindcxBot::Regime::AiBrain do
  describe '.overlay_from_state' do
    it 'returns empty hash when there is no payload and no error' do
      expect(described_class.overlay_from_state({})).to eq({})
    end

    it 'maps error to a TUI overlay' do
      o = described_class.overlay_from_state(error: 'connection refused')
      expect(o[:active]).to be(false)
      expect(o[:status]).to eq('PIPE:ERR')
      expect(o[:hmm_display]).to include('connection refused')
    end

    it 'maps a successful payload to active regime fields' do
      payload = {
        regime_label: 'RANGING',
        probability_pct: 71,
        stability_bars: 4,
        flicker_hint: 'low',
        confirmed: true,
        vol_rank: 2,
        vol_rank_total: 5,
        transition_summary: 'mostly range-bound',
        notes: 'ATR compressed vs prior week'
      }
      o = described_class.overlay_from_state(payload: payload)
      expect(o[:active]).to be(true)
      expect(o[:label]).to eq('RANGING')
      expect(o[:probability_pct]).to eq(71)
      expect(o[:stability_bars]).to eq(4)
      expect(o[:flicker_display]).to eq('low')
      expect(o[:confirmed]).to be(true)
      expect(o[:vol_rank_display]).to eq('2/5')
      expect(o[:status]).to eq('PIPE:RUN')
      expect(o[:hmm_display]).to include('ATR compressed')
    end
  end

  describe 'JSON parsing (shared SmcSetup::JsonSlice)' do
    it 'parses regime JSON wrapped in markdown fences' do
      raw = <<~JSON
        ```json
        {"regime_label":"X","probability_pct":50,"stability_bars":1,"flicker_hint":"low","confirmed":false,"vol_rank":1,"vol_rank_total":5,"transition_summary":"t","notes":"n"}
        ```
      JSON
      h = CoindcxBot::SmcSetup::JsonSlice.parse_object(raw)
      expect(h[:regime_label]).to eq('X')
      expect(h[:probability_pct]).to eq(50)
    end

    context 'when the model emits trailing commas (invalid strict JSON)' do
      it 'parses a multi-line object with a trailing comma before the closing brace' do
        raw = <<~JSON
          {
            "regime_label": "LOW_VOL",
            "probability_pct": 100,
            "stability_bars": 3,
            "flicker_hint": "low",
            "confirmed": true,
            "vol_rank": 2,
            "vol_rank_total": 4,
            "transition_summary": "quiet",
            "notes": "ok",
          }
        JSON
        h = CoindcxBot::SmcSetup::JsonSlice.parse_object(raw)
        expect(h[:regime_label]).to eq('LOW_VOL')
        expect(h[:probability_pct]).to eq(100)
      end
    end
  end
end
