# frozen_string_literal: true

RSpec.describe CoindcxBot::Notifications::HumanJournalEventMessage do
  describe '.format' do
    it 'formats signal_open for a human reader' do
      s = described_class.format(
        'signal_open',
        action: 'open_long',
        pair: 'B-ETH_USDT',
        reason: 'meta_first_win(pullback_to_ema)',
        leverage: 5
      )
      expect(s).to include('coindcx-bot | signal_open')
      expect(s).to include('Open LONG · B-ETH_USDT')
      expect(s).to include('Reason: meta_first_win(pullback_to_ema)')
      expect(s).to include('Leverage: 5x')
      expect(s).not_to include('{')
    end

    it 'rounds paper_realized money fields' do
      s = described_class.format(
        'paper_realized',
        position_id: 33,
        pair: 'B-ETH_USDT',
        pnl_usdt: '-1.117549608308918400000000000000038456793984',
        pnl_inr: '-109.519861614274003200000000000003768765810432',
        exit_price: '2383.3448178853571428571428571428571143',
        source: 'broker_stop_loss'
      )
      expect(s).to include('Paper PnL (realized)')
      expect(s).to include('Pair: B-ETH_USDT')
      expect(s).to include('Position: #33')
      expect(s).to match(/PnL: -1\.1175 USDT/)
      expect(s).to match(/~₹-109\.52/)
      expect(s).to include('Exit: 2383.3448')
      expect(s).to include('Source: broker_stop_loss')
      expect(s).not_to include('000038456793984')
    end

    it 'formats signal_close with yes/no for pnl_booked' do
      s = described_class.format(
        'signal_close',
        pair: 'B-ETH_USDT',
        reason: 'hwm_giveback',
        position_id: 35,
        outcome: 'closed',
        pnl_booked: true
      )
      expect(s).to include('Close')
      expect(s).to include('Pair: B-ETH_USDT')
      expect(s).to include('Reason: hwm_giveback')
      expect(s).to include('Position: #35')
      expect(s).to include('Outcome: closed')
      expect(s).to include('PnL booked: yes')
    end

    it 'formats open_failed' do
      s = described_class.format(
        'open_failed',
        pair: 'B-ETH_USDT',
        action: 'open_long',
        reason: 'meta_first_win(x)',
        detail: 'broker_rejected'
      )
      expect(s).to include('Open failed')
      expect(s).to include('Detail: broker_rejected')
    end

    it 'formats ws_order_update from snippet keys' do
      s = described_class.format(
        'ws_order_update',
        'event' => 'fill',
        'status' => 'done',
        'id' => '99'
      )
      expect(s).to include('Order (WebSocket update)')
      expect(s).to include('event: fill')
      expect(s).to include('status: done')
    end

    it 'uses labeled fallback for unknown event types' do
      s = described_class.format('custom_audit', foo: 'bar', n: 1)
      expect(s).to include('Event: custom_audit')
      expect(s).to include('foo: bar')
      expect(s).to include('n: 1')
    end

    it 'accepts string-keyed payloads from JSON round-trip' do
      s = described_class.format(
        'signal_open',
        'action' => 'open_short',
        'pair' => 'B-SOL_USDT',
        'reason' => 'x',
        'leverage' => 3
      )
      expect(s).to include('Open SHORT · B-SOL_USDT')
    end

    it 'formats analysis_strategy_transition' do
      s = described_class.format(
        'analysis_strategy_transition',
        pair: 'B-SOL_USDT',
        from_action: 'hold',
        from_reason: 'no_flip',
        to_action: 'open_long',
        to_reason: 'supertrend_bull_flip',
        ltp: '100.5'
      )
      expect(s).to include('Strategy Transition')
      expect(s).to include('B-SOL_USDT')
      expect(s).to include('OPEN_LONG')
      expect(s).to include('LTP: 100.5')
    end

    it 'formats analysis_strategy_transition LTP without scientific notation' do
      s = described_class.format(
        'analysis_strategy_transition',
        pair: 'B-SOL_USDT',
        from_action: 'hold',
        from_reason: 'x',
        to_action: 'hold',
        to_reason: 'y',
        ltp: '0.8636e2'
      )
      expect(s).to include('LTP: 86.36')
    end

    it 'formats analysis_price_cross' do
      s = described_class.format(
        'analysis_price_cross',
        pair: 'B-SOL_USDT',
        rule_id: 'r1',
        direction: 'below→above',
        price: '101',
        level: 'above 100',
        label: 'test',
        threshold_summary: 'above 100',
        strategy_action: 'hold',
        strategy_reason: 'no_signal',
        hmm_label: 'S2',
        hmm_state_id: '2',
        hmm_posterior_pct: '72.5',
        hmm_vol_rank: '2/4',
        hmm_uncertain: 'false',
        regime_ai_label: 'RANGING',
        regime_ai_probability_pct: '40.0'
      )
      expect(s).to include('Price level cross (LTP)')
      expect(s).to include('101')
      expect(s).to include('HMM:')
      expect(s).to include('Regime AI (book-wide):')
    end

    it 'formats analysis_regime_change' do
      s = described_class.format(
        'analysis_regime_change',
        pair: 'B-SOL_USDT',
        from_state: 0,
        to_state: 1,
        from_label: 'low',
        to_label: 'high'
      )
      expect(s).to include('HMM regime change')
      expect(s).to include('B-SOL_USDT')
    end

    it 'formats analysis_regime_ai_update' do
      s = described_class.format(
        'analysis_regime_ai_update',
        pair: 'B-SOL_USDT',
        from_label: 'range',
        to_label: 'trend',
        from_probability_pct: 40.0,
        to_probability_pct: 55.0
      )
      expect(s).to include('Regime AI')
    end

    it 'formats analysis_liquidation_proximity' do
      s = described_class.format(
        'analysis_liquidation_proximity',
        pair: 'B-SOL_USDT',
        side: 'long',
        distance_pct: 2.5,
        ltp: '100',
        liq: '97.5'
      )
      expect(s).to include('Liquidation')
      expect(s).to include('2.5')
    end

    it 'formats smc_setup_identified with direction, zone, sl, targets' do
      s = described_class.format(
        'smc_setup_identified',
        setup_id: 'sol_20260424_001',
        pair: 'B-SOL_USDT',
        direction: 'long',
        entry_min: '85.0',
        entry_max: '85.5',
        sl: '84.2',
        targets: '86.5,87.5',
        risk_usdt: '30',
        leverage: '10'
      )
      expect(s).to include('SMC setup identified')
      expect(s).to include('Direction: LONG')
      expect(s).to include('Entry zone: 85.0 - 85.5')
      expect(s).to include('Stop-loss: 84.2')
      expect(s).to include('Targets: 86.5,87.5')
      expect(s).to include('Risk: 30 USDT')
    end

    it 'formats smc_setup_armed with gate flag' do
      s = described_class.format(
        'smc_setup_armed',
        setup_id: 'id1', pair: 'B-ETH_USDT', direction: 'short',
        entry_min: '2305', entry_max: '2310', sl: '2320', gate_ok: 'approved'
      )
      expect(s).to include('ARMED')
      expect(s).to include('Gate: approved')
      expect(s).to include('Direction: SHORT')
    end

    it 'formats smc_setup_fired with entry price and size' do
      s = described_class.format(
        'smc_setup_fired',
        setup_id: 'id1', pair: 'B-SOL_USDT', direction: 'long',
        entry_min: '85.0', entry_max: '85.5', sl: '84.2',
        entry_price: '85.3', quantity: '12.5'
      )
      expect(s).to include('FIRED')
      expect(s).to include('Entry filled: 85.3')
      expect(s).to include('Size: 12.5')
    end

    it 'formats smc_setup_invalidated with reason and ltp' do
      s = described_class.format(
        'smc_setup_invalidated',
        setup_id: 'id1', pair: 'B-SOL_USDT', direction: 'long',
        sl: '84.2', reason: 'hmm_conflict:TREND_DN', ltp: '83.9'
      )
      expect(s).to include('INVALIDATED')
      expect(s).to include('Reason: hmm_conflict:TREND_DN')
      expect(s).to include('LTP: 83.9')
    end
  end
end
