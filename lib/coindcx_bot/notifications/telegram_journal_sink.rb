# frozen_string_literal: true

require 'cgi'
require 'net/http'
require_relative 'human_journal_event_message'
require 'set'
require 'uri'
require 'thread'

module CoindcxBot
  module Notifications
    # Optional mirror of +Journal#log_event+ rows to Telegram. Off unless
    # +Config#telegram_journal_notifications_ready?+ (ENV token + chat id). Delivery is async
    # (bounded queue); failures never propagate to callers.
    class TelegramJournalSink
      MAX_QUEUE = 500
      MAX_BODY_CHARS = 3_500

      def self.build_if_configured(config:, logger:)
        return nil unless config.telegram_journal_notifications_ready?

        new(
          main_token: config.telegram_journal_bot_token,
          main_chat: config.telegram_journal_chat_id.to_s,
          ops_token: config.telegram_journal_ops_bot_token,
          ops_chat: config.telegram_journal_ops_chat_id.to_s,
          ops_types: config.telegram_journal_ops_duplicate_types,
          logger: logger,
          http: TelegramHttpPoster.new
        )
      end

      def initialize(main_token:, main_chat:, ops_token:, ops_chat:, ops_types:, logger:, http:)
        @main_token = main_token
        @main_chat = main_chat
        @ops_token = ops_token
        @ops_chat = ops_chat
        @ops_types = ops_types.map(&:to_s).to_set
        @logger = logger
        @http = http
        @queue = Queue.new
        @worker = nil
        start_worker_unlocked!
      end

      # Non-blocking: enqueue after journal INSERT; never raises.
      def deliver(type, payload)
        item = [type.to_s, payload_hash(payload)]
        if @queue.size >= MAX_QUEUE
          @logger&.warn('[telegram_journal] queue full — dropping notification')
          return
        end

        @queue.push(item)
      rescue StandardError => e
        @logger&.warn("[telegram_journal] enqueue failed: #{e.class}: #{e.message}")
      end

      private

      def payload_hash(payload)
        return {} unless payload.is_a?(Hash)

        payload.transform_keys(&:to_sym)
      end

      def start_worker_unlocked!
        return if @worker&.alive?

        @worker = Thread.new { worker_loop }
        @worker.name = 'telegram_journal_sink'
        @worker.abort_on_exception = false
        @worker.report_on_exception = false
      end

      def worker_loop
        loop do
          type, payload = @queue.pop
          dispatch(type, payload)
        end
      end

      def dispatch(type, payload)
        text = format_message(type, payload)
        post_safe(@main_token, @main_chat, text)
        post_safe(@ops_token, @ops_chat, text) if duplicate_to_ops?(type)
      end

      def duplicate_to_ops?(type)
        return false if @ops_chat.strip.empty?
        return false if @ops_chat == @main_chat
        return false if @ops_types.empty?

        @ops_types.include?(type)
      end

      def format_message(type, payload)
        text = HumanJournalEventMessage.format(type, payload)
        return text if text.length <= MAX_BODY_CHARS

        "#{text[0, MAX_BODY_CHARS]}…"
      end

      def post_safe(token, chat_id, text)
        return if token.to_s.strip.empty? || chat_id.to_s.strip.empty?

        @http.post_message(token: token, chat_id: chat_id, text: text)
      rescue StandardError => e
        @logger&.warn("[telegram_journal] send failed: #{e.class}: #{e.message}")
      end
    end

    # Stdlib HTTP — tiny surface for tests via stub instance.
    class TelegramHttpPoster
      def post_message(token:, chat_id:, text:)
        uri = URI("https://api.telegram.org/bot#{token}/sendMessage")
        req = Net::HTTP::Post.new(uri.request_uri)
        req.set_form_data(
          'chat_id' => chat_id.to_s,
          'text' => text,
          'disable_web_page_preview' => 'true'
        )
        Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, open_timeout: 2, read_timeout: 8) do |http|
          res = http.request(req)
          unless res.is_a?(Net::HTTPSuccess)
            raise "telegram HTTP #{res.code}: #{CGI.escapeHTML(res.body.to_s)[0, 200]}"
          end
        end
      end
    end
  end
end
