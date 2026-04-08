# frozen_string_literal: true

module CoindcxBot
  module Gateways
    module Concerns
      module ErrorMapping
        private

        def map_coin_dcx_error(error)
          case error
          when CoinDCX::Errors::AuthError, CoinDCX::Errors::AuthenticationError
            Result.fail(:auth, error.message)
          when CoinDCX::Errors::RateLimitError
            Result.fail(:rate_limit, error.message)
          when CoinDCX::Errors::RequestError
            Result.fail(:request, error.message)
          when CoinDCX::Errors::SocketConnectionError, CoinDCX::Errors::SocketError
            Result.fail(:socket, error.message)
          when CoinDCX::Errors::ValidationError
            Result.fail(:validation, error.message)
          when CoinDCX::Errors::Error
            Result.fail(:coindcx, error.message)
          else
            Result.fail(:unknown, error.message)
          end
        end

        def guard_call
          Result.ok(yield)
        rescue CoinDCX::Errors::Error => e
          map_coin_dcx_error(e)
        rescue StandardError => e
          Result.fail(:internal, e.message)
        end
      end
    end
  end
end
