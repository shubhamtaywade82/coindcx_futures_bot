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
  end
end
