# frozen_string_literal: true

require 'coindcx'

require_relative 'coindcx_bot/version'
require_relative 'coindcx_bot/gateways/result'
require_relative 'coindcx_bot/gateways/concerns/error_mapping'
require_relative 'coindcx_bot/gateways/market_data_gateway'
require_relative 'coindcx_bot/gateways/order_gateway'
require_relative 'coindcx_bot/gateways/account_gateway'
require_relative 'coindcx_bot/gateways/ws_gateway'
require_relative 'coindcx_bot/dto/tick'
require_relative 'coindcx_bot/dto/candle'
require_relative 'coindcx_bot/config'
require_relative 'coindcx_bot/core/event_bus'
require_relative 'coindcx_bot/persistence/journal'
require_relative 'coindcx_bot/position_tracker'
require_relative 'coindcx_bot/risk/exposure_guard'
require_relative 'coindcx_bot/risk/manager'
require_relative 'coindcx_bot/strategy/indicators'
require_relative 'coindcx_bot/strategy/trend_continuation'
require_relative 'coindcx_bot/execution/coordinator'
require_relative 'coindcx_bot/core/engine'
require_relative 'coindcx_bot/doctor'
require_relative 'coindcx_bot/cli'
require_relative 'coindcx_bot/tui/app'

module CoindcxBot
end
