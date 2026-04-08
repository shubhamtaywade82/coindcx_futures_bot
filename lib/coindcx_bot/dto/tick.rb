# frozen_string_literal: true

module CoindcxBot
  module Dto
    Tick = Struct.new(:pair, :price, :change_pct, :received_at, keyword_init: true)
  end
end
