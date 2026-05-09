# frozen_string_literal: true

require 'spec_helper'
require 'coindcx_bot'
require 'ollama-client'

RSpec.describe CoindcxBot::OllamaChatFallback do
  describe '.same_endpoint?' do
    it 'treats trailing slashes and default ports as equivalent' do
      expect(described_class.same_endpoint?('http://127.0.0.1:11434/', 'http://127.0.0.1:11434')).to be(true)
    end

    it 'distinguishes different hosts' do
      expect(described_class.same_endpoint?('https://ollama.com', 'http://127.0.0.1:11434')).to be(false)
    end
  end

  describe '.eligible_for_fallback?' do
    it 'returns false when primary and fallback are the same endpoint' do
      err = Ollama::TimeoutError.new('slow')
      ok = described_class.eligible_for_fallback?(
        err,
        primary_base_url: 'http://127.0.0.1:11434',
        fallback_base_url: 'http://127.0.0.1:11434',
        fallback_model: 'llama3.2:3b'
      )
      expect(ok).to be(false)
    end

    it 'returns false when fallback model is blank' do
      err = Ollama::TimeoutError.new('slow')
      ok = described_class.eligible_for_fallback?(
        err,
        primary_base_url: 'https://ollama.com',
        fallback_base_url: 'http://127.0.0.1:11434',
        fallback_model: '  '
      )
      expect(ok).to be(false)
    end

    it 'returns true for retryable HTTP errors when endpoints differ' do
      err = Ollama::HTTPError.new('bad gateway', 502)
      ok = described_class.eligible_for_fallback?(
        err,
        primary_base_url: 'https://ollama.com',
        fallback_base_url: 'http://127.0.0.1:11434',
        fallback_model: 'llama3.2:3b'
      )
      expect(ok).to be(true)
    end

    it 'returns false for invalid JSON errors' do
      err = Ollama::InvalidJSONError.new('garbage')
      ok = described_class.eligible_for_fallback?(
        err,
        primary_base_url: 'https://ollama.com',
        fallback_base_url: 'http://127.0.0.1:11434',
        fallback_model: 'llama3.2:3b'
      )
      expect(ok).to be(false)
    end
  end

  describe '.chat_with_local_fallback' do
    it 'retries on the fallback client when primary raises a retryable error' do
      primary = instance_double(Ollama::Client)
      fallback = instance_double(Ollama::Client)
      response = instance_double('response', content: '{"ok":true}')

      expect(primary).to receive(:chat).once.and_raise(Ollama::HTTPError.new('unavailable', 503))
      expect(described_class).to receive(:fallback_client).with(
        'http://127.0.0.1:11434',
        '',
        30,
        0.1
      ).and_return(fallback)
      expect(fallback).to receive(:chat).with(
        hash_including(
          messages: [{ role: 'user', content: 'hi' }],
          model: 'llama3.2:3b',
          format: 'json',
          stream: false
        )
      ).and_return(response)

      got = described_class.chat_with_local_fallback(
        logger: nil,
        log_tag: 'test',
        messages: [{ role: 'user', content: 'hi' }],
        format: 'json',
        stream: false,
        options: { temperature: 0.1 },
        primary_client: primary,
        primary_model: 'cloud-model',
        primary_base_url: 'https://ollama.com',
        fallback_base_url: 'http://127.0.0.1:11434',
        fallback_model: 'llama3.2:3b',
        fallback_api_key: '',
        fallback_timeout: 30,
        fallback_temperature: 0.1
      )
      expect(got).to eq(response)
    end

    it 're-raises when primary fails and fallback is the same endpoint' do
      primary = instance_double(Ollama::Client)
      expect(primary).to receive(:chat).and_raise(Ollama::HTTPError.new('unavailable', 503))
      expect(described_class).not_to receive(:fallback_client)

      expect do
        described_class.chat_with_local_fallback(
          logger: nil,
          log_tag: 'test',
          messages: [{ role: 'user', content: 'hi' }],
          format: 'json',
          stream: false,
          options: { temperature: 0.1 },
          primary_client: primary,
          primary_model: 'm',
          primary_base_url: 'http://127.0.0.1:11434',
          fallback_base_url: 'http://127.0.0.1:11434',
          fallback_model: 'llama3.2:3b',
          fallback_api_key: '',
          fallback_timeout: 30,
          fallback_temperature: 0.1
        )
      end.to raise_error(Ollama::HTTPError)
    end
  end
end
