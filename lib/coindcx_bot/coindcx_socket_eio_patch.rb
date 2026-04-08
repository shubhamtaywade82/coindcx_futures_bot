# frozen_string_literal: true

# The published `coindcx-client` calls `SocketIO::Client::Simple.connect(url)` with no Engine.IO
# version. CoinDCX's Socket.IO endpoint expects `EIO=3` or `EIO=4` on the handshake query string.
# This prepend works for Git-sourced gems that do not expose `Configuration#socket_io_connect_options`.
module CoindcxBot
  module CoindcxSocketEioPatch
    def connect(url)
      raw = ENV['COINDCX_SOCKET_EIO'].to_s.strip
      eio = raw.empty? ? 4 : Integer(raw)
      @socket = @socket_factory.connect(url, { EIO: eio })
    rescue StandardError => e
      raise CoinDCX::Errors::SocketConnectionError, e.message
    end
  end
end

CoinDCX::WS::SocketIOSimpleBackend.prepend(CoindcxBot::CoindcxSocketEioPatch)
