# frozen_string_literal: true

RSpec.describe CoindcxBot::Regime::AiBrain do
  describe '#build_user_message' do
    let(:brain) { described_class.new(config: CoindcxBot::Config.new(minimal_bot_config), logger: nil) }

    it 'embeds OHLCV feature JSON when features_by_pair is present' do
      ctx = {
        exec_resolution: '15m',
        htf_resolution: '1h',
        positions: [],
        pairs: %w[B-SOL_USDT],
        candles_by_pair: { 'B-SOL_USDT' => [{ o: 1, h: 2, l: 1, c: 1.5, v: 1 }] },
        features_by_pair: { 'B-SOL_USDT' => { symbol: 'B-SOL_USDT', price: 1.5 } }
      }
      msg = brain.send(:build_user_message, ctx)
      expect(msg).to include('OHLCV feature packets')
      expect(msg).to include('B-SOL_USDT')
    end

    it 'embeds authoritative open_positions_json instead of Ruby inspect' do
      ctx = {
        exec_resolution: '15m',
        htf_resolution: '1h',
        positions: [
          { pair: 'B-SOL_USDT', side: 'long', entry_price: '85.63', quantity: '227.19', id: 42, stop_price: '80' }
        ],
        pairs: %w[B-SOL_USDT],
        candles_by_pair: { 'B-SOL_USDT' => [{ o: 1, h: 2, l: 1, c: 1.5, v: 1 }] }
      }
      msg = brain.send(:build_user_message, ctx)
      expect(msg).to include('open_positions_json')
      expect(msg).not_to include(':side=>')
      parsed = msg.lines.find { |l| l.strip.start_with?('[') }
      expect(JSON.parse(parsed.strip)).to contain_exactly(
        a_hash_including(
          'pair' => 'B-SOL_USDT',
          'side' => 'long',
          'entry_price' => '85.63',
          'quantity' => '227.19',
          'position_id' => '42',
          'stop_price' => '80'
        )
      )
    end
  end

  describe '.serialize_open_positions' do
    it 'drops rows without a pair and normalizes string keys' do
      rows = [
        { 'pair' => 'B-ETH_USDT', 'side' => 'SHORT', 'entry_price' => '2300', 'quantity' => '1', 'id' => 7 },
        { 'pair' => '', 'side' => 'long' }
      ]
      expect(described_class.serialize_open_positions(rows)).to contain_exactly(
        {
          position_id: '7',
          pair: 'B-ETH_USDT',
          side: 'short',
          entry_price: '2300',
          quantity: '1'
        }
      )
    end
  end

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
      expect(o[:ai_transition_full]).to eq('mostly range-bound')
      expect(o[:ai_notes_full]).to eq('ATR compressed vs prior week')
    end

    it 'exposes full error text for TUI wrap lines' do
      o = described_class.overlay_from_state(error: 'model timeout')
      expect(o[:ai_notes_full]).to eq('model timeout')
      expect(o[:ai_transition_full]).to eq('')
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

    context 'when the model appends junk after the closing brace' do
      it 'parses only the first object (avoids json_ensure_eof comma after value)' do
        raw = '{"regime_label":"X","probability_pct":99,"stability_bars":1,"flicker_hint":"low",' \
              '"confirmed":false,"vol_rank":1,"vol_rank_total":5,"transition_summary":"t","notes":"n"} ,'
        h = CoindcxBot::SmcSetup::JsonSlice.parse_object(raw)
        expect(h[:regime_label]).to eq('X')
        expect(h[:probability_pct]).to eq(99)
      end

      it 'parses the first object when two objects are concatenated' do
        raw = '{"regime_label":"FIRST","probability_pct":1,"stability_bars":0,"flicker_hint":"low",' \
              '"confirmed":false,"vol_rank":1,"vol_rank_total":5,"transition_summary":"","notes":""}' \
              '{"regime_label":"SECOND","probability_pct":2,"stability_bars":0,"flicker_hint":"low",' \
              '"confirmed":false,"vol_rank":1,"vol_rank_total":5,"transition_summary":"","notes":""}'
        h = CoindcxBot::SmcSetup::JsonSlice.parse_object(raw)
        expect(h[:regime_label]).to eq('FIRST')
      end
    end
  end
end
