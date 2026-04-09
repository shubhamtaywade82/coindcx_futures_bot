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
end
