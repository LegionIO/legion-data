# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module Data
    module Rls
      extend Legion::Logging::Helper

      RLS_TABLES = %i[
        tasks digital_workers audit_log memory_traces extensions
        functions runners nodes settings value_metrics
      ].freeze

      module_function

      def rls_enabled?
        return false unless Legion::Settings[:data][:connected]

        Legion::Data.connection.adapter_scheme == :postgres
      rescue StandardError => e
        handle_exception(e, level: :warn, handled: true, operation: :rls_enabled)
        false
      end

      def assign_tenant(tenant_id)
        return unless rls_enabled?

        Legion::Data.connection.run(
          Sequel.lit('SET app.current_tenant = ?', tenant_id.to_s)
        )
      end

      def current_tenant
        return nil unless rls_enabled?

        Legion::Data.connection.fetch('SHOW app.current_tenant').first&.values&.first
      rescue Sequel::DatabaseError => e
        handle_exception(e, level: :warn, handled: true, operation: :current_tenant)
        nil
      end

      def reset_tenant
        return unless rls_enabled?

        Legion::Data.connection.run('RESET app.current_tenant')
      end

      def with_tenant(tenant_id)
        return yield unless rls_enabled?

        Legion::Data.connection.synchronize do
          previous = current_tenant
          begin
            assign_tenant(tenant_id)
            yield
          ensure
            previous ? assign_tenant(previous) : reset_tenant
          end
        end
      end
    end
  end
end
