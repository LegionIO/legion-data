# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module Data
    module AuthFailureHandler
      extend Legion::Logging::Helper

      AUTH_FAILURE_PATTERNS = [
        /role .* does not exist/i,
        /password authentication failed/i,
        /authentication failed/i,
        /no pg_hba\.conf entry/i,
        /permission denied for table/i,
        /permission denied for relation/i
      ].freeze

      REISSUE_COOLDOWN = 30

      @last_reissue_at = nil
      @mutex = Mutex.new

      module SequelHook
        def connect(server)
          super
        rescue StandardError => e
          Legion::Data::AuthFailureHandler.handle(e)
          raise
        end

        def raise_error(exception, opts = Sequel::OPTS)
          Legion::Data::AuthFailureHandler.handle(exception)
          super
        end
      end

      class << self
        def install(sequel_db)
          sequel_db.singleton_class.prepend(SequelHook)
        end

        def handle(error)
          return unless auth_failure?(error)
          return if on_cooldown?

          request_reissue(error)
        end

        def auth_failure?(error)
          message = error.message.to_s
          AUTH_FAILURE_PATTERNS.any? { |pattern| message.match?(pattern) }
        end

        def on_cooldown?
          @mutex.synchronize do
            return false unless @last_reissue_at

            (Time.now - @last_reissue_at) < REISSUE_COOLDOWN
          end
        end

        def request_reissue(error, adapter: :postgresql)
          @mutex.synchronize { @last_reissue_at = Time.now }
          log.error("Legion::Data auth failure detected: #{error.message} — requesting lease reissue")

          return unless defined?(Legion::Crypt::LeaseManager)

          Legion::Crypt::LeaseManager.instance.reissue_lease(adapter)
        rescue StandardError => e
          handle_exception(e, level: :error, handled: true, operation: :auth_failure_reissue)
        end

        def reset!
          @mutex.synchronize { @last_reissue_at = nil }
        end
      end
    end
  end
end
