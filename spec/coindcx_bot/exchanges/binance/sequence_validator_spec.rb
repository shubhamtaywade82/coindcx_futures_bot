# frozen_string_literal: true

RSpec.describe CoindcxBot::Exchanges::Binance::SequenceValidator do
  describe '.validate_initial!' do
    context 'when the snapshot id is bracketed by the first event' do
      it 'returns nil without raising for U == L+1' do
        expect(described_class.validate_initial!(first_u: 101, final_u: 105, snapshot_id: 100)).to be_nil
      end

      it 'returns nil without raising when L+1 sits inside [U, u]' do
        expect(described_class.validate_initial!(first_u: 90, final_u: 110, snapshot_id: 100)).to be_nil
      end
    end

    context 'when the first event starts after the snapshot boundary' do
      it 'raises Desync because U > L+1 means we missed events' do
        expect do
          described_class.validate_initial!(first_u: 102, final_u: 110, snapshot_id: 100)
        end.to raise_error(described_class::Desync, /U=102 u=110 snapshot=100/)
      end
    end

    context 'when the first event finishes before the snapshot boundary' do
      it 'raises Desync because u < L+1 means the event predates the snapshot' do
        expect do
          described_class.validate_initial!(first_u: 90, final_u: 99, snapshot_id: 100)
        end.to raise_error(described_class::Desync)
      end
    end
  end

  describe '.validate_continuity!' do
    it 'returns nil when pu equals the last applied final update id' do
      expect(described_class.validate_continuity!(prev_u: 105, last_applied_u: 105)).to be_nil
    end

    it 'raises Desync when pu does not match the last applied final update id' do
      expect do
        described_class.validate_continuity!(prev_u: 104, last_applied_u: 105)
      end.to raise_error(described_class::Desync, /pu=104 expected=105/)
    end
  end
end
