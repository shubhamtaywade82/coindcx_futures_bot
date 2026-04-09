# frozen_string_literal: true

RSpec.describe CoindcxBot::Execution::FillEngine do
  subject(:engine) { described_class.new(slippage_bps: 5, fee_bps: 4) }

  describe '#fill_market_order' do
    context 'long entry' do
      let(:fill) { engine.fill_market_order(side: 'long', quantity: BigDecimal('1'), ltp: BigDecimal('100')) }

      it 'applies positive slippage to fill price' do
        expected_price = BigDecimal('100') * (BigDecimal('1') + BigDecimal('5') / 10_000)
        expect(fill[:fill_price]).to eq(expected_price)
      end

      it 'calculates fee from fill price and quantity' do
        expected_fee = fill[:fill_price] * BigDecimal('1') * BigDecimal('4') / 10_000
        expect(fill[:fee]).to eq(expected_fee)
      end

      it 'records slippage amount' do
        expect(fill[:slippage]).to be > 0
      end

      it 'returns full quantity' do
        expect(fill[:quantity]).to eq(BigDecimal('1'))
      end
    end

    context 'short entry' do
      let(:fill) { engine.fill_market_order(side: 'short', quantity: BigDecimal('2'), ltp: BigDecimal('200')) }

      it 'applies negative slippage to fill price' do
        expected_price = BigDecimal('200') * (BigDecimal('1') - BigDecimal('5') / 10_000)
        expect(fill[:fill_price]).to eq(expected_price)
      end

      it 'calculates fee correctly' do
        expected_fee = fill[:fill_price] * BigDecimal('2') * BigDecimal('4') / 10_000
        expect(fill[:fee]).to eq(expected_fee)
      end
    end

    context 'long/short symmetry' do
      let(:long_fill) { engine.fill_market_order(side: 'long', quantity: BigDecimal('1'), ltp: BigDecimal('100')) }
      let(:short_fill) { engine.fill_market_order(side: 'short', quantity: BigDecimal('1'), ltp: BigDecimal('100')) }

      it 'long fill price is higher than LTP' do
        expect(long_fill[:fill_price]).to be > BigDecimal('100')
      end

      it 'short fill price is lower than LTP' do
        expect(short_fill[:fill_price]).to be < BigDecimal('100')
      end

      it 'slippage amounts are equal for symmetric entries' do
        expect(long_fill[:slippage]).to eq(short_fill[:slippage])
      end
    end

    context 'zero slippage and fees' do
      subject(:engine) { described_class.new(slippage_bps: 0, fee_bps: 0) }

      it 'fills at exact LTP with no fee' do
        fill = engine.fill_market_order(side: 'long', quantity: BigDecimal('1'), ltp: BigDecimal('100'))
        expect(fill[:fill_price]).to eq(BigDecimal('100'))
        expect(fill[:fee]).to eq(BigDecimal('0'))
        expect(fill[:slippage]).to eq(BigDecimal('0'))
      end
    end
  end

  describe '#evaluate' do
    let(:wo_market) do
      CoindcxBot::Execution::OrderBook::WorkingOrder.new(
        id: 1, pair: 'B-SOL_USDT', side: 'long', order_type: 'market',
        quantity: BigDecimal('1'), anchor_price: BigDecimal('100'),
        limit_price: nil, stop_price: nil, group_id: nil, group_role: nil
      )
    end

    it 'fills market with trigger' do
      f = engine.evaluate(wo_market, ltp: BigDecimal('100'))
      expect(f[:trigger]).to eq(:market_order)
      expect(f[:fill_price]).to be > BigDecimal('100')
    end

    it 'returns nil for zero or missing ltp' do
      expect(engine.evaluate(wo_market, ltp: BigDecimal('0'))).to be_nil
      expect(engine.evaluate(wo_market, ltp: nil)).to be_nil
    end

    it 'fills long limit when ltp trades down to limit' do
      wo = CoindcxBot::Execution::OrderBook::WorkingOrder.new(
        id: 2, pair: 'B-SOL_USDT', side: 'long', order_type: 'limit',
        quantity: BigDecimal('1'), anchor_price: BigDecimal('100'),
        limit_price: BigDecimal('98'), stop_price: nil, group_id: nil, group_role: nil
      )
      expect(engine.evaluate(wo, ltp: BigDecimal('99'))).to be_nil
      f = engine.evaluate(wo, ltp: BigDecimal('98'))
      expect(f[:fill_price]).to eq(BigDecimal('98'))
      expect(f[:trigger]).to eq(:limit_order)
      expect(f[:slippage]).to eq(BigDecimal('0'))
    end

    it 'fills long limit when low wicks through' do
      wo = CoindcxBot::Execution::OrderBook::WorkingOrder.new(
        id: 3, pair: 'B-SOL_USDT', side: 'long', order_type: 'limit',
        quantity: BigDecimal('1'), anchor_price: BigDecimal('100'),
        limit_price: BigDecimal('98'), stop_price: nil, group_id: nil, group_role: nil
      )
      f = engine.evaluate(wo, ltp: BigDecimal('99'), high: nil, low: BigDecimal('97.5'))
      expect(f).not_to be_nil
      expect(f[:fill_price]).to eq(BigDecimal('98'))
    end

    it 'fills short limit when high touches' do
      wo = CoindcxBot::Execution::OrderBook::WorkingOrder.new(
        id: 4, pair: 'B-SOL_USDT', side: 'short', order_type: 'limit',
        quantity: BigDecimal('1'), anchor_price: BigDecimal('100'),
        limit_price: BigDecimal('102'), stop_price: nil, group_id: nil, group_role: nil
      )
      expect(engine.evaluate(wo, ltp: BigDecimal('101'))).to be_nil
      f = engine.evaluate(wo, ltp: BigDecimal('102'))
      expect(f[:fill_price]).to eq(BigDecimal('102'))
    end

    it 'stop-loss sell when price breaks down' do
      wo = CoindcxBot::Execution::OrderBook::WorkingOrder.new(
        id: 5, pair: 'B-SOL_USDT', side: 'sell', order_type: 'stop_market',
        quantity: BigDecimal('1'), anchor_price: BigDecimal('100'),
        limit_price: nil, stop_price: BigDecimal('95'), group_id: nil, group_role: nil
      )
      expect(engine.evaluate(wo, ltp: BigDecimal('96'))).to be_nil
      f = engine.evaluate(wo, ltp: BigDecimal('95'))
      expect(f[:trigger]).to eq(:stop_loss)
    end

    it 'take-profit sell when price reaches target' do
      wo = CoindcxBot::Execution::OrderBook::WorkingOrder.new(
        id: 6, pair: 'B-SOL_USDT', side: 'sell', order_type: 'take_profit',
        quantity: BigDecimal('1'), anchor_price: BigDecimal('100'),
        limit_price: nil, stop_price: BigDecimal('110'), group_id: nil, group_role: nil
      )
      expect(engine.evaluate(wo, ltp: BigDecimal('109'))).to be_nil
      f = engine.evaluate(wo, ltp: BigDecimal('110'))
      expect(f[:trigger]).to eq(:take_profit)
    end

    it 'stop-loss buy for short when price breaks up' do
      wo = CoindcxBot::Execution::OrderBook::WorkingOrder.new(
        id: 7, pair: 'B-SOL_USDT', side: 'buy', order_type: 'stop',
        quantity: BigDecimal('1'), anchor_price: BigDecimal('100'),
        limit_price: nil, stop_price: BigDecimal('105'), group_id: nil, group_role: nil
      )
      expect(engine.evaluate(wo, ltp: BigDecimal('104'))).to be_nil
      f = engine.evaluate(wo, ltp: BigDecimal('105'))
      expect(f[:trigger]).to eq(:stop_loss)
    end
  end
end
