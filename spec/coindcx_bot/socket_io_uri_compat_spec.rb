# frozen_string_literal: true

RSpec.describe 'socket_io URI compat' do
  it 'defines URI.encode for socket.io-client-simple on Ruby 3+' do
    expect(URI).to respond_to(:encode)
    expect(URI.encode('EIO=4')).to eq('EIO=4')
    expect(URI.encode('transport=websocket')).to eq('transport=websocket')
  end
end
