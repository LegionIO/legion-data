# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module Data
    module Settings
      extend Legion::Logging::Helper

      CREDS = {
        sqlite:   {
          database: 'legionio.db'
        },
        mysql2:   {
          username: 'legion',
          password: 'legion',
          database: 'legionio',
          host:     '127.0.0.1',
          port:     3306
        },
        postgres: {
          user:     'legion',
          password: 'legion',
          database: 'legionio',
          host:     '127.0.0.1',
          port:     5432
        }
      }.freeze

      def self.default
        {
          adapter:                       'sqlite',
          connected:                     false,

          # Connection pool
          max_connections:               25,
          pool_timeout:                  5,
          preconnect:                    false,
          single_threaded:               false,
          test:                          true,
          name:                          nil,

          # Logging
          log:                           false,
          query_log:                     false,
          log_connection_info:           false,
          log_warn_duration:             1,
          sql_log_level:                 'debug',

          # Connection health (network adapters only, ignored for sqlite)
          # Validation is disabled by default: the connection_validator extension issues a
          # SELECT NULL on every checkout/checkin and before real queries, which kills
          # throughput. Connection errors are already rescued and reconnected at query time.
          # When enabled, connection_validation_timeout: -1 validates on every checkout
          # (catches stale connections from VPN/sleep/network changes immediately).
          connection_validation:         false,
          connection_validation_timeout: -1,
          connection_expiration:         true,
          connection_expiration_timeout: 14_400,

          # Postgres session timeouts (milliseconds, applied via SET on each new connection).
          # statement_timeout bounds any single query; lock_timeout bounds lock acquisition.
          # These prevent a wedged SELECT or lock wait from hanging the process indefinitely.
          statement_timeout:             5000,
          lock_timeout:                  2000,

          # TCP keepalives for Postgres (libpq connection params).
          # Detect half-open sockets where the peer vanished without FIN/RST.
          # keepalives_idle: seconds before first keepalive probe after idle
          # keepalives_interval: seconds between probes
          # keepalives_count: failed probes before declaring connection dead
          # tcp_user_timeout: total ms for unacked data before kernel drops connection (Linux)
          keepalives:                    1,
          keepalives_idle:               10,
          keepalives_interval:           5,
          keepalives_count:              3,
          tcp_user_timeout:              15_000,

          # Shutdown: max seconds to wait for checked-out connections to return before
          # force-disconnecting them.
          shutdown_timeout:              5,

          # Adapter-specific (nil = use adapter built-in default)
          connect_timeout:               nil,
          read_timeout:                  nil,
          write_timeout:                 nil,
          encoding:                      nil,
          sql_mode:                      nil,
          sslmode:                       nil,
          sslrootcert:                   nil,
          search_path:                   nil,
          timeout:                       nil,
          readonly:                      nil,
          disable_dqs:                   nil,

          # Grouped settings
          creds:                         creds,
          cache:                         cache,
          migrations:                    migrations,
          models:                        models,
          local:                         local,
          dev_mode:                      false,
          dev_fallback:                  true,
          connect_on_start:              true,
          read_replica_url:              nil,
          replicas:                      [],
          archival:                      archival
        }
      end

      def self.local
        {
          enabled:    true,
          database:   'legionio_local.db',
          query_log:  false,
          migrations: { auto_migrate: true }
        }
      end

      def self.models
        {
          continue_on_load_fail: false,
          autoload:              true
        }
      end

      def self.migrations
        {
          continue_on_fail: false,
          auto_migrate:     true,
          ran:              false,
          version:          nil
        }
      end

      def self.creds(adapter = nil)
        adapter = (adapter || :sqlite).to_sym
        CREDS.fetch(adapter, CREDS[:sqlite]).dup
      end

      def self.archival
        {
          retention_days:  90,
          batch_size:      1000,
          storage_backend: nil
        }
      end

      def self.cache
        {
          connected:    false,
          auto_enable:  Legion::Settings[:cache][:connected],
          static_cache: false,
          ttl:          60
        }
      end
    end
  end
end

begin
  Legion::Settings.merge_settings('data', Legion::Data::Settings.default) if Legion.const_defined?('Settings', false)
rescue StandardError => e
  Legion::Data::Settings.handle_exception(e, level: :fatal, operation: :merge_settings)
end
