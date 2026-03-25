# frozen_string_literal: true

module Legion
  module Data
    module Settings
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
          preconnect:                    'concurrently',
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
          connection_validation:         true,
          connection_validation_timeout: 600,
          connection_expiration:         true,
          connection_expiration_timeout: 14_400,

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
  Legion::Settings.merge_settings('data', Legion::Data::Settings.default) if Legion.const_defined?('Settings')
rescue StandardError => e
  Legion::Logging.fatal(e.message) if Legion::Logging.method_defined?(:fatal)
end
