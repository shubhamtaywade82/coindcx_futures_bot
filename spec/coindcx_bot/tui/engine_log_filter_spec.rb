# frozen_string_literal: true

require 'spec_helper'

RSpec.describe CoindcxBot::Tui::EngineLogFilter do
  let(:inner) { instance_double(TTY::Logger, info: nil, warn: nil, error: nil, debug: nil) }
  subject(:filter) { described_class.new(inner) }

  around do |example|
    saved = ENV['COINDCX_TUI_LOG_ALL']
    ENV.delete('COINDCX_TUI_LOG_ALL')
    example.run
  ensure
    if saved
      ENV['COINDCX_TUI_LOG_ALL'] = saved
    else
      ENV.delete('COINDCX_TUI_LOG_ALL')
    end
  end

  it 'forwards api_call failures at info' do
    payload = { event: 'api_call', response_status: 500 }
    filter.info(payload)
    expect(inner).to have_received(:info).with(payload)
  end

  it 'drops successful api_call at info by default' do
    payload = { event: 'api_call', response_status: 200 }
    filter.info(payload)
    expect(inner).not_to have_received(:info)
  end

  it 'forwards successful api_call when COINDCX_TUI_LOG_ALL=1' do
    ENV['COINDCX_TUI_LOG_ALL'] = '1'
    payload = { event: 'api_call', response_status: 200 }
    filter.info(payload)
    expect(inner).to have_received(:info).with(payload)
  end

  it 'drops ws_disconnected warnings by default' do
    payload = { event: 'ws_disconnected', endpoint: 'wss://stream.coindcx.com' }
    filter.warn(payload)
    expect(inner).not_to have_received(:warn)
  end

  it 'forwards ws_disconnected when COINDCX_TUI_LOG_ALL=1' do
    ENV['COINDCX_TUI_LOG_ALL'] = '1'
    payload = { event: 'ws_disconnected' }
    filter.warn(payload)
    expect(inner).to have_received(:warn).with(payload)
  end

  it 'forwards other warnings' do
    payload = { event: 'ws_heartbeat_stale' }
    filter.warn(payload)
    expect(inner).to have_received(:warn).with(payload)
  end

  it 'always forwards errors' do
    payload = { event: 'api_call_failed' }
    filter.error(payload)
    expect(inner).to have_received(:error).with(payload)
  end
end
