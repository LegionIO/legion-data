# frozen_string_literal: true

require 'sequel'
require 'sequel/extensions/migration'

module Legion
  module Data
    module Local
      class << self
        attr_reader :connection, :db_path

        def setup(database: nil, **)
          return if @connected

          db_file = database || local_settings[:database] || 'legionio_local.db'
          @db_path = db_file

          sqlite_defaults = Legion::Data::Connection::ADAPTER_DEFAULTS.fetch(:sqlite, {})
          data = defined?(Legion::Settings) ? Legion::Settings[:data] : {}
          opts = { adapter: :sqlite, database: db_file }
          Legion::Data::Connection::ADAPTER_KEYS.fetch(:sqlite, []).each do |key|
            val = data.key?(key) && !data[key].nil? ? data[key] : sqlite_defaults[key]
            opts[key] = val unless val.nil?
          end

          if local_settings[:query_log]
            log_path = File.join(Legion::Data::Connection::QUERY_LOG_DIR, 'data-local-query.log')
            @query_file_logger = Legion::Data::Connection::QueryFileLogger.new(log_path)
            opts[:logger]        = @query_file_logger
            opts[:sql_log_level] = :debug
          end

          @connection = ::Sequel.connect(opts)
          @connected = true
          run_migrations
          Legion::Logging.info "Legion::Data::Local connected to #{db_file}" if defined?(Legion::Logging)
        end

        def shutdown
          @connection&.disconnect
          @query_file_logger&.close
          @query_file_logger = nil
          @connection = nil
          @connected = false
        end

        def connected?
          @connected == true
        end

        def register_migrations(name:, path:)
          @registered_migrations ||= {}
          @registered_migrations[name] = path
          run_single_migration(name, path) if connected?
        end

        def registered_migrations
          @registered_migrations || {}
        end

        def model(table_name)
          raise 'Legion::Data::Local not connected' unless connected?

          ::Sequel::Model(connection[table_name])
        end

        def stats
          return { connected: false } unless connected?

          stats = {
            connected:             true,
            adapter:               :sqlite,
            path:                  @db_path,
            query_log:             local_settings[:query_log] || false,
            query_log_path:        @query_file_logger&.path,
            registered_migrations: registered_migrations.keys
          }

          stats[:file_size] = File.size(@db_path) if @db_path && File.exist?(@db_path)

          %w[page_size page_count freelist_count journal_mode
             wal_autocheckpoint cache_size busy_timeout].each do |pragma|
            val = begin
              @connection.fetch("PRAGMA #{pragma}").single_value
            rescue StandardError
              nil
            end
            stats[pragma.to_sym] = val unless val.nil?
          end

          stats[:database_size_bytes] = stats[:page_size].to_i * stats[:page_count].to_i if stats[:page_size] && stats[:page_count]

          stats
        rescue StandardError => e
          { connected: connected?, error: e.message }
        end

        def reset!
          @connection = nil
          @connected = false
          @db_path = nil
          @registered_migrations = nil
        end

        private

        def run_migrations
          return unless local_settings.dig(:migrations, :auto_migrate) != false

          registered_migrations.each do |name, path|
            run_single_migration(name, path)
          end
        end

        def run_single_migration(name, path)
          return unless local_settings.dig(:migrations, :auto_migrate) != false
          return unless File.directory?(path)

          table = :"schema_migrations_#{name}"
          ::Sequel::TimestampMigrator.new(@connection, path, table: table).run
        rescue StandardError => e
          Legion::Logging.warn "Local migration failed for #{path}: #{e.message}" if defined?(Legion::Logging)
        end

        def local_settings
          return {} unless defined?(Legion::Settings)

          Legion::Settings[:data]&.dig(:local) || {}
        end
      end
    end
  end
end
