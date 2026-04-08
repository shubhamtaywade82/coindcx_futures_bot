# frozen_string_literal: true

RSpec.describe 'CoindcxSocketEioPatch' do
  it 'prepends so SocketIOSimpleBackend uses Engine.IO handshake options' do
    expect(CoinDCX::WS::SocketIOSimpleBackend.ancestors).to include(CoindcxBot::CoindcxSocketEioPatch)
  end
end
