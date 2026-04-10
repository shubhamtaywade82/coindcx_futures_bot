# frozen_string_literal: true

module CoindcxBot
  module PaperExchange
    # WEBrick serves requests on a thread pool; a single SQLite3::Database must not be used concurrently.
    # Serialize the inner app so every SQL statement runs on one thread at a time.
    module SqlMutex
      class Middleware
        def initialize(app, store:)
          @app = app
          @store = store
        end

        def call(env)
          @store.synchronize_sql { @app.call(env) }
        end
      end
    end
  end
end
