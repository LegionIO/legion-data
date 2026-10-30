# frozen_string_literal: true

require 'legion/logging/helper'
require 'openssl'

module Legion
  module Data
    module Encryption
      class KeyProvider
        include Legion::Logging::Helper

        def initialize(mode: :auto)
          @mode = mode
          @key_cache = {}
        end

        def key_for(tenant_id: nil)
          @key_cache[tenant_id] ||= derive_key(tenant_id)
        end

        def clear_cache!
          @key_cache.clear
          log.debug 'Cleared encryption key cache'
        end

        private

        def derive_key(tenant_id)
          if tenant_id && crypt_available?
            log.debug "Deriving Vault key for tenant #{tenant_id}"
            Legion::Crypt::PartitionKeys.derive(tenant_id: tenant_id)
          elsif crypt_available?
            Legion::Crypt.default_encryption_key
          else
            log.warn 'Legion::Crypt unavailable, falling back to dev encryption key'
            local_key
          end
        rescue StandardError => e
          handle_exception(e, level: :error, handled: false, operation: :derive_key, tenant_id: tenant_id)
          raise
        end

        def crypt_available?
          defined?(Legion::Crypt::PartitionKeys)
        end

        def local_key
          OpenSSL::Digest.digest('SHA256', 'legion-dev-encryption-key')
        end
      end
    end
  end
end
