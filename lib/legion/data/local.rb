# frozen_string_literal: true

require 'fileutils'
require 'legion/logging/helper'

require 'sequel'
require 'sequel/extensions/migration'

module Legion
  module Data
    module Local
      class << self
        include Legion::Logging::Helper

        attr_reader :connection, :db_path

        def setup(database: nil, **)
          return if @connected

          db_file = database || local_settings[:database] || 'legionio_local.db'
          unless File.absolute_path?(db_file)
            base_dir = File.expand_path('~/.legionio')
            FileUtils.mkdir_p(base_dir)
            db_file = File.join(base_dir, db_file)
          end
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
            opts[:logger]          = @query_file_logger
            opts[:sql_log_level]   = :debug
          elsif data[:log]
            opts[:logger]          = build_local_logger
            opts[:sql_log_level]   = resolved_sql_log_level
            opts[:log_warn_duration] = resolved_log_warn_duration
          end

          @connection = ::Sequel.connect(opts)
          @connection.run('PRAGMA journal_mode=WAL')
          @connection.run('PRAGMA busy_timeout=30000')
          @connection.run('PRAGMA synchronous=NORMAL')
          @connection.run('PRAGMA cache_size=-20000')
          @connection.run('PRAGMA mmap_size=268435456')
          @connected = true
          run_migrations
          log.info "Legion::Data::Local connected to #{db_file} (WAL mode, 30s busy_timeout, 20MB cache, 256MB mmap)"
        rescue StandardError => e
          handle_exception(e, level: :error, handled: false, operation: :local_setup, database: db_file)
          raise
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
             wal_autocheckpoint cache_size busy_timeout mmap_size].each do |pragma|
            val = begin
              @connection.fetch("PRAGMA #{pragma}").single_value
            rescue StandardError => e
              handle_exception(e, level: :warn, handled: true, operation: :local_stats_pragma, pragma: pragma)
              nil
            end
            stats[pragma.to_sym] = val unless val.nil?
          end

          stats[:database_size_bytes] = stats[:page_size].to_i * stats[:page_count].to_i if stats[:page_size] && stats[:page_count]

          stats
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: true, operation: :local_stats, database: @db_path)
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
          handle_exception(e, level: :warn, handled: true, operation: :local_migration, name: name, path: path)
        end

        def local_settings
          return {} unless defined?(Legion::Settings)

          Legion::Settings[:data]&.dig(:local) || {}
        end

        def build_local_logger
          tagged = if defined?(Legion::Logging::TaggedLogger) && respond_to?(:tagged_logger_settings, true)
                     Legion::Logging::TaggedLogger.new(
                       segments: %w[data local],
                       **send(:tagged_logger_settings)
                     )
                   else
                     Legion::Data::Connection::SegmentedTaggedLogger.new(segments: %w[data local])
                   end
          Legion::Data::Connection::SlowQueryLogger.new(tagged)
        rescue StandardError => e
          if respond_to?(:handle_exception, true)
            handle_exception(e, level: :warn, handled: true, operation: :build_local_logger)
          else
            log.warn("build_local_logger failed: #{e.class}: #{e.message}")
          end
          Legion::Data::Connection::SlowQueryLogger.new(
            Legion::Data::Connection::SegmentedTaggedLogger.new(segments: %w[data local], logger: log)
          )
        end

        def resolved_sql_log_level
          (local_settings[:sql_log_level] || Legion::Settings[:data][:sql_log_level] || 'debug').to_sym
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: true, operation: :resolved_sql_log_level)
          :debug
        end

        def resolved_log_warn_duration
          local_settings[:log_warn_duration] || Legion::Settings[:data][:log_warn_duration]
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: true, operation: :resolved_log_warn_duration)
          nil
        end
      end
    end
  end
end
