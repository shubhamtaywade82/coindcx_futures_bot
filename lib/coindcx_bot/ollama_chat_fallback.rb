# frozen_string_literal: true

require 'uri'
require 'net/http'

module CoindcxBot
  # Retries a chat completion against local Ollama when the primary endpoint fails
  # with transport, timeout, or typical cloud outage errors.
  module OllamaChatFallback
    module_function

    def same_endpoint?(primary_url, fallback_url)
      normalize_endpoint(primary_url) == normalize_endpoint(fallback_url)
    end

    def normalize_endpoint(url)
      s = url.to_s.strip.chomp('/')
      return '' if s.empty?

      u = s.include?('://') ? s : "http://#{s}"
      uri = URI.parse(u)
      port = uri.port
      default_port = uri.scheme == 'https' ? 443 : 80
      host = uri.host.to_s.downcase
      port_part = port && port != default_port ? ":#{port}" : ''
      "#{uri.scheme}://#{host}#{port_part}"
    rescue URI::InvalidURIError, ArgumentError
      s.downcase
    end

    def eligible_for_fallback?(error, primary_base_url:, fallback_base_url:, fallback_model:)
      return false if fallback_model.to_s.strip.empty?
      return false if fallback_base_url.to_s.strip.empty?
      return false if same_endpoint?(primary_base_url, fallback_base_url)

      retryable_to_local?(error)
    end

    def retryable_to_local?(error)
      ensure_ollama_loaded!
      case error
      when Ollama::TimeoutError, Ollama::NotFoundError, Ollama::RetryExhaustedError
        true
      when Ollama::HTTPError
        return true if error.respond_to?(:retryable?) && error.retryable?

        code = error.respond_to?(:status_code) ? error.status_code : nil
        [401, 403, 404, 429].include?(code)
      when Ollama::InvalidJSONError, Ollama::SchemaViolationError
        false
      when Ollama::Error
        retryable_ollama_generic_message?(error.message)
      when SocketError, Net::OpenTimeout, Net::ReadTimeout
        true
      when Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ENETUNREACH, Errno::ECONNRESET, Errno::ETIMEDOUT
        true
      else
        openssl_ssl_error?(error)
      end
    end

    def chat_with_local_fallback(logger:, log_tag:, messages:, format:, stream:, options:,
                                   primary_client:, primary_model:, primary_base_url:,
                                   fallback_base_url:, fallback_model:, fallback_api_key:,
                                   fallback_timeout:, fallback_temperature:)
      ensure_ollama_loaded!
      primary_client.chat(
        messages: messages,
        model: primary_model,
        format: format,
        stream: stream,
        options: options
      )
    rescue StandardError => e
      unless eligible_for_fallback?(e, primary_base_url: primary_base_url, fallback_base_url: fallback_base_url,
                                    fallback_model: fallback_model)
        raise
      end

      logger&.warn(
        "[#{log_tag}] primary Ollama unavailable (#{e.class}: #{e.message}) — " \
        "retrying local #{normalize_endpoint(fallback_base_url)} model=#{fallback_model}"
      )
      fallback_client(fallback_base_url, fallback_api_key, fallback_timeout, fallback_temperature).chat(
        messages: messages,
        model: fallback_model,
        format: format,
        stream: stream,
        options: options
      )
    end

    def fallback_client(base_url, api_key, timeout, temperature)
      ensure_ollama_loaded!
      cfg = Ollama::Config.new
      cfg.base_url = base_url unless base_url.to_s.strip.empty?
      k = api_key.to_s.strip
      cfg.api_key = k unless k.empty?
      cfg.timeout = timeout
      cfg.temperature = temperature
      Ollama::Client.new(config: cfg)
    end

    def ensure_ollama_loaded!
      return if defined?(Ollama) && defined?(Ollama::Client)

      require 'ollama-client'
    end

    def retryable_ollama_generic_message?(message)
      msg = message.to_s.downcase
      msg.include?('connection') || msg.include?('timed out') || msg.include?('timeout') ||
        msg.include?('failed to connect') || msg.include?('could not connect') ||
        msg.include?('tcp') || msg.include?('reset by peer')
    end

    def openssl_ssl_error?(error)
      defined?(OpenSSL::SSL::SSLError) && error.is_a?(OpenSSL::SSL::SSLError)
    end
  end
end
