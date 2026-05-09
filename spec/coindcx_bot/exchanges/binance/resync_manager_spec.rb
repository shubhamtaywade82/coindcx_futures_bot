# frozen_string_literal: true

require 'bigdecimal'
require_relative '../../../support/fake_depth_ws'

RSpec.describe CoindcxBot::Exchanges::Binance::ResyncManager do
  let(:book) { CoindcxBot::Exchanges::Binance::LocalBook.new }
  let(:rest) { instance_double(CoindcxBot::Exchanges::Binance::FuturesRest) }
  let(:ws)   { FakeDepthWs.new }
  let(:logger) { nil }
  let(:cycle_scripts) { [] }

  let(:sleeper) do
    lambda do |_seconds|
      script = cycle_scripts.shift
      next if script.nil?

      result = script.call
      events = result.is_a?(Array) ? result : [result]
      events.each { |event| ws.push_event(event) }
    end
  end

  let(:manager) do
    described_class.new(
      symbol: 'BTCUSDT',
      rest: rest,
      depth_ws: ws,
      book: book,
      logger: logger,
      max_attempts: 3,
      buffer_warmup_seconds: 0,
      retry_backoff_seconds: 0,
      sleeper: sleeper
    )
  end

  def bd(value) = BigDecimal(value.to_s)

  def event(first_u:, final_u:, prev_u:, bids: [], asks: [])
    CoindcxBot::Exchanges::Binance::DepthWs::Event.new(
      event_type: 'depthUpdate',
      symbol: 'BTCUSDT',
      first_u: first_u,
      final_u: final_u,
      prev_u: prev_u,
      event_time: 0,
      tx_time: 0,
      bids: bids.map { |(p, q)| [bd(p), bd(q)] },
      asks: asks.map { |(p, q)| [bd(p), bd(q)] }
    )
  end

  def snapshot(last_update_id:, bids: [], asks: [])
    CoindcxBot::Exchanges::Binance::FuturesRest::Snapshot.new(
      last_update_id: last_update_id,
      bids: bids.map { |(p, q)| [bd(p), bd(q)] },
      asks: asks.map { |(p, q)| [bd(p), bd(q)] }
    )
  end

  describe '#replay_buffer!' do
    it 'discards events whose final_u is at or before the snapshot id' do
      stale = event(first_u: 50, final_u: 60, prev_u: nil, bids: [['100', '1.0']])
      first_live = event(first_u: 99, final_u: 105, prev_u: 95, bids: [['100', '5.0']])

      manager.replay_buffer!(
        buffered_events: [stale, first_live],
        snapshot: snapshot(last_update_id: 100, bids: [['100', '1.0']])
      )

      expect(book.last_update_id).to eq(105)
      expect(book.best_bid).to eq([bd('100'), bd('5.0')])
    end

    it 'raises Desync when the first relevant event starts after L+1' do
      gap = event(first_u: 110, final_u: 120, prev_u: nil)

      expect do
        manager.replay_buffer!(
          buffered_events: [gap],
          snapshot: snapshot(last_update_id: 100)
        )
      end.to raise_error(CoindcxBot::Exchanges::Binance::SequenceValidator::Desync, /U=110/)
    end

    it 'raises Desync when subsequent events have a continuity gap' do
      first  = event(first_u: 99, final_u: 105, prev_u: 95)
      second = event(first_u: 106, final_u: 110, prev_u: 104) # pu mismatch (expected 105)

      expect do
        manager.replay_buffer!(
          buffered_events: [first, second],
          snapshot: snapshot(last_update_id: 100)
        )
      end.to raise_error(CoindcxBot::Exchanges::Binance::SequenceValidator::Desync, /pu=104 expected=105/)
    end
  end

  describe '#step!' do
    before do
      manager.replay_buffer!(
        buffered_events: [event(first_u: 99, final_u: 105, prev_u: 95)],
        snapshot: snapshot(last_update_id: 100)
      )
    end

    it 'applies the next event when pu matches last_applied_u' do
      manager.step!(event(first_u: 106, final_u: 110, prev_u: 105, bids: [['101', '2.0']]))

      expect(book.last_update_id).to eq(110)
      expect(book.best_bid).to eq([bd('101'), bd('2.0')])
    end

    it 'raises Desync when pu drifts from last_applied_u' do
      expect do
        manager.step!(event(first_u: 106, final_u: 110, prev_u: 999))
      end.to raise_error(CoindcxBot::Exchanges::Binance::SequenceValidator::Desync)
    end
  end

  describe '#start' do
    let(:aligned_event) { event(first_u: 99, final_u: 105, prev_u: 95, bids: [['100', '5.0']]) }
    let(:misaligned_event) { event(first_u: 110, final_u: 120, prev_u: nil) }

    it 'connects, fetches snapshot, replays buffer, then transitions to live' do
      allow(rest).to receive(:depth).and_return(snapshot(last_update_id: 100))
      cycle_scripts << -> { aligned_event }

      manager.start

      expect(ws).to be_connected
      expect(book.last_update_id).to eq(105)
      expect(manager.state).to eq(:live)
      expect(book.best_bid).to eq([bd('100'), bd('5.0')])
    end

    it 'applies live events that arrive after sync' do
      allow(rest).to receive(:depth).and_return(snapshot(last_update_id: 100))
      cycle_scripts << -> { aligned_event }
      manager.start

      ws.push_event(event(first_u: 106, final_u: 110, prev_u: 105, asks: [['200', '7.0']]))

      expect(book.last_update_id).to eq(110)
      expect(book.best_ask).to eq([bd('200'), bd('7.0')])
    end

    it 'raises GaveUp after exhausting alignment retries' do
      allow(rest).to receive(:depth).and_return(snapshot(last_update_id: 100))
      cycle_scripts.replace(Array.new(5) { -> { misaligned_event } })

      expect { manager.start }.to raise_error(described_class::GaveUp, /3 alignment attempts/)
      expect(rest).to have_received(:depth).exactly(3).times
    end

    it 'recovers when a later alignment attempt succeeds' do
      allow(rest).to receive(:depth).and_return(snapshot(last_update_id: 100))
      cycle_scripts.replace([
                              -> { misaligned_event },
                              -> { aligned_event },
                            ])

      manager.start

      expect(manager.state).to eq(:live)
      expect(book.last_update_id).to eq(105)
    end
  end
end
