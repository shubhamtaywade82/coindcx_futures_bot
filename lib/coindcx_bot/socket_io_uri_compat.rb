# frozen_string_literal: true

require 'uri'

# socket.io-client-simple 1.2.x builds the Socket.IO query string with `URI.encode`, which was
# removed in Ruby 3.0+. Reintroduce it via the RFC2396 parser escape used by legacy URI.encode.
unless URI.respond_to?(:encode)
  module URI
    def self.encode(str)
      DEFAULT_PARSER.escape(str.to_s)
    end
  end
end
