# frozen_string_literal: true

require 'legion/logging/helper'
require 'legion/data/auth_failure_handler'

require 'fileutils'
require 'sequel'

module Legion
  module Data
    module Connection
      ADAPTERS = %i[sqlite mysql2 postgres].freeze

      UNRESOLVED_URI_PATTERN = %r{\A(?:vault|env|lease)://}

      class UnresolvedCredentialError < StandardError; end

      GENERIC_KEYS = %i[max_connections pool_timeout preconnect single_threaded test name].freeze

      ADAPTER_KEYS = {
        sqlite:   %i[timeout readonly disable_dqs],
        postgres: %i[connect_timeout sslmode sslrootcert search_path],
        mysql2:   %i[connect_timeout read_timeout write_timeout encoding sql_mode]
      }.freeze

      ADAPTER_DEFAULTS = {
        sqlite:   { timeout: 5000, readonly: false, disable_dqs: true },
        postgres: { connect_timeout: 20, sslmode: 'disable' },
        mysql2:   { connect_timeout: 120, encoding: 'utf8mb4' }
      }.freeze

      QUERY_LOG_DIR = File.expand_path('~/.legionio/logs').freeze

      # Wraps a tagged Legion::Logging::Logger for Sequel's logger interface.
      # Prefixes warn-level messages with [slow-query] since Sequel uses warn
      # for queries exceeding log_warn_duration.
      class SlowQueryLogger
        attr_reader :tagged

        def initialize(tagged_logger)
          @tagged = tagged_logger
        end

        def warn(message)
          @tagged.warn("[slow-query] #{message}")
        end

        def info(message)
          @tagged.info(message)
        end

        def debug(message)
          @tagged.debug(message)
        end

        def error(message)
          @tagged.error(message)
        end
      end

      class SegmentedTaggedLogger
        attr_reader :segments

        def initialize(segments:, logger: nil)
          @segments = segments
          @logger = logger || Legion::Logging
        end

        def warn(message)
          with_segments { dispatch(:warn, message) }
        end

        def info(message)
          with_segments { dispatch(:info, message) }
        end

        def debug(message)
          with_segments { dispatch(:debug, message) }
        end

        def error(message)
          with_segments { dispatch(:error, message) }
        end

        private

        def dispatch(level, message)
          return unless @logger.respond_to?(level)

          @logger.public_send(level, message)
        end

        def with_segments
          previous = Thread.current[:legion_log_segments]
          Thread.current[:legion_log_segments] = @segments
          yield
        ensure
          Thread.current[:legion_log_segments] = previous
        end
      end

      # File-based query logger that writes all SQL to a dedicated log file.
      # Isolated from the main Legion::Logging domain.
      class QueryFileLogger
        include Legion::Logging::Helper

        attr_reader :path

        def initialize(path)
          @path = path
          @closed = false
          @mutex = Mutex.new
          dir = File.dirname(path)
          FileUtils.mkdir_p(dir)
          FileUtils.chmod(0o700, dir) if File.directory?(dir)
          @file = File.open(path, File::WRONLY | File::APPEND | File::CREAT, 0o600)
          @file.sync = true
        end

        def debug(message)
          write('DEBUG', message)
        end

        def info(message)
          write('INFO', message)
        end

        def warn(message)
          write('WARN', message)
        end

        def error(message)
          write('ERROR', message)
        end

        def close
          @mutex.synchronize do
            @closed = true
            @file.close unless @file.closed?
          end
        end

        private

        def write(level, message)
          @mutex.synchronize do
            return if @closed || @file.closed?

            @file.puts "[#{Time.now.strftime('%Y-%m-%d %H:%M:%S.%L')}] #{level} #{message}"
          end
        rescue IOError => e
          return nil if @closed || @file.closed?

          handle_exception(e, level: :warn, handled: true, operation: :query_file_write, path: @path)
          nil
        end
      end

      class << self
        include Legion::Logging::Helper

        attr_accessor :sequel

        def adapter
          @adapter ||= Legion::Settings[:data][:adapter]&.to_sym || :sqlite
        end

        def setup
          @adapter = Legion::Settings[:data][:adapter]&.to_sym || :sqlite
          opts = sequel_opts
          log.info("Legion::Data::Connection setup adapter=#{adapter}")
          @fallback_active = false
          @sequel = if adapter == :sqlite
                      ::Sequel.connect(opts.merge(adapter: :sqlite, database: sqlite_path))
                    else
                      attempted_adapter = adapter
                      begin
                        ::Sequel.connect(connection_opts_for(adapter: attempted_adapter, opts: opts))
                      rescue UnresolvedCredentialError => e
                        handle_exception(e, level: :fatal, handled: false, operation: :data_connect)
                        raise
                      rescue StandardError => e
                        raise unless dev_fallback?

                        log.error("Legion::Data FALLING BACK TO SQLITE — #{attempted_adapter} network DB connection failed: #{e.message}")
                        log.error("Legion::Data WARNING: Data written to SQLite will NOT be visible when #{attempted_adapter} reconnects. " \
                                  'Apollo knowledge, audit logs, and other DB-backed services will use a local-only store.')
                        handle_exception(e, level: :error, handled: true, operation: :shared_connect, fallback: :sqlite)
                        @adapter = :sqlite
                        @fallback_active = true
                        sqlite_opts = sequel_opts
                        ::Sequel.connect(sqlite_opts.merge(adapter: :sqlite, database: sqlite_path))
                      end
                    end
          Legion::Settings[:data][:connected] = true
          log_connection_info
          configure_extensions
          connect_with_replicas
        end

        # Returns connection metadata for health checks and diagnostics.
        # Apollo and other services can use this to detect silent fallback.
        def connection_info
          {
            adapter:            adapter,
            connected:          Legion::Settings[:data][:connected],
            fallback_active:    @fallback_active || false,
            configured_adapter: Legion::Settings[:data][:adapter]&.to_sym || :sqlite,
            sequel_alive:       (begin
              !@sequel&.test_connection.nil?
            rescue StandardError => e
              log.debug("connection health check failed: #{e.message}")
              false
            end)
          }
        end

        # Returns true if the data layer fell back to SQLite from a configured
        # network database (PostgreSQL/MySQL). Services should check this and
        # log warnings when operating in degraded mode.
        def fallback_active?
          @fallback_active == true
        end

        def stats
          return { connected: false } unless @sequel

          data = Legion::Settings[:data]
          {
            connected: data[:connected],
            adapter:   adapter,
            pool:      pool_stats,
            tuning:    tuning_stats(data),
            database:  database_stats
          }
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: true, operation: :data_connection_stats, adapter: adapter)
          { connected: (data[:connected] if data.is_a?(Hash)), adapter: adapter, error: e.message }
        end

        def pool_stats
          return {} unless @sequel

          pool = @sequel.pool
          stats = {
            type:     pool.pool_type,
            size:     pool.size,
            max_size: pool.respond_to?(:max_size) ? pool.max_size : nil
          }

          case pool.pool_type
          when :timed_queue, :sharded_timed_queue
            queue_size = pool.instance_variable_get(:@queue)&.size || 0
            stats[:available] = queue_size
            stats[:in_use]    = stats[:size] - queue_size
            stats[:waiting]   = pool.num_waiting
          when :threaded, :sharded_threaded
            avail = pool.instance_variable_get(:@available_connections)
            stats[:available] = avail&.size || 0
            stats[:in_use]    = stats[:size] - stats[:available]
            stats[:waiting]   = pool.num_waiting
          when :single, :sharded_single
            stats[:available] = pool.size
            stats[:in_use]    = 0
            stats[:waiting]   = 0
          end

          stats.compact
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: true, operation: :data_pool_stats, adapter: adapter)
          {}
        end

        def shutdown
          @sequel&.disconnect
          @query_file_logger&.close
          @query_file_logger = nil
          @fallback_active = false
          Legion::Settings[:data][:connected] = false
          log.info 'Legion::Data connection closed'
        end

        def reconnect_with_fresh_creds
          return false unless @sequel
          return false if adapter == :sqlite

          fresh_creds = Legion::Settings[:data][:creds]
          return false unless fresh_creds.is_a?(Hash)

          new_user = fresh_creds[:user] || fresh_creds[:username]
          new_pass = fresh_creds[:password]

          unless new_user && new_pass
            log.error('reconnect_with_fresh_creds: no user/password in Settings[:data][:creds]')
            return false
          end

          old_user = @sequel.opts[:user]
          @sequel.opts[:user] = new_user
          @sequel.opts[:password] = new_pass

          @sequel.disconnect

          @sequel.test_connection
          log.info("reconnect_with_fresh_creds: rotated credentials (#{old_user} → #{new_user})")
          true
        rescue StandardError => e
          handle_exception(e, level: :error, handled: true, operation: :reconnect_with_fresh_creds,
                           old_user: old_user, new_user: new_user)
          false
        end


        def connect_with_replicas
          return unless adapter == :postgres

          replica_url  = Legion::Settings[:data][:read_replica_url]
          replica_list = Array(Legion::Settings[:data][:replicas]).dup

          replica_list.prepend(replica_url) if replica_url && !replica_url.empty?
          replica_list.uniq!
          replica_list.compact!

          return if replica_list.empty?

          @sequel.extension(:server_block)

          replica_list.each_with_index do |url, idx|
            @sequel.add_servers("read_#{idx}": url)
          end

          @replica_servers = replica_list.each_with_index.map { |_, idx| :"read_#{idx}" }
          log.debug "Registered #{@replica_servers.size} read replica(s)"
        end

        def read_server
          return :default if @replica_servers.nil? || @replica_servers.empty?

          :read_0
        end

        def replica_servers
          @replica_servers || []
        end

        def merge_tls_creds(creds, adapter:, port:)
          return creds if adapter == :sqlite
          return creds unless defined?(Legion::Crypt::TLS)

          tls_settings = data_tls_settings
          return creds unless tls_settings[:enabled] == true

          tls = Legion::Crypt::TLS.resolve(tls_settings, port: port)
          return creds unless tls[:enabled]

          case adapter
          when :postgres
            creds[:sslmode]     = tls[:verify] == :none ? 'require' : 'verify-full'
            creds[:sslrootcert] = tls[:ca] if tls[:ca]
            creds[:sslcert]     = tls[:cert] if tls[:cert]
            creds[:sslkey]      = tls[:key] if tls[:key]
          when :mysql2
            creds[:ssl_mode] = tls[:verify] == :none ? 'required' : 'verify_identity'
            creds[:sslca]    = tls[:ca] if tls[:ca]
            creds[:sslcert]  = tls[:cert] if tls[:cert]
            creds[:sslkey]   = tls[:key] if tls[:key]
          end

          creds
        end

        def creds_builder(final_creds = {})
          final_creds.merge! Legion::Data::Settings.creds(adapter)
          final_creds.merge! Legion::Settings[:data][:creds] if Legion::Settings[:data][:creds].is_a? Hash

          port = final_creds[:port]
          merge_tls_creds(final_creds, adapter: adapter, port: port)

          final_creds
        end

        private

        def data_tls_settings
          return {} unless defined?(Legion::Settings)

          Legion::Settings[:data][:tls] || {}
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: true, operation: :data_tls_settings)
          {}
        end

        def log_connection_info
          if adapter == :sqlite
            log.info "Connected to SQLite at #{sqlite_path}"
          else
            actual = Legion::Settings[:data][:creds] || {}
            conn_user = actual[:user] || actual[:username] || 'unknown'
            conn_host = actual[:host] || '127.0.0.1'
            conn_port = actual[:port]
            conn_db   = actual[:database] || actual[:db]
            lease_id  = current_lease_id
            msg = "Connected to #{adapter}://#{conn_user}@#{conn_host}:#{conn_port}/#{conn_db}"
            msg += " lease_id=#{lease_id}" if lease_id
            log.info msg
          end
        end

        def current_lease_id
          return unless defined?(Legion::Crypt::LeaseManager)

          Legion::Crypt::LeaseManager.instance.active_leases.dig(:postgresql, :lease_id)
        rescue StandardError
          nil
        end

        def dev_fallback?
          data_settings = Legion::Settings[:data]
          data_settings[:dev_mode] == true && data_settings[:dev_fallback] != false
        end

        def sqlite_path
          path = Legion::Settings[:data][:creds][:database] || 'legionio.db'
          return path if File.absolute_path?(path)

          base_dir = File.expand_path('~/.legionio/data')
          FileUtils.mkdir_p(base_dir)
          File.join(base_dir, path)
        end

        def connection_opts_for(adapter:, opts:)
          connection_opts = opts.merge(adapter: adapter, **creds_builder)
          validate_no_unresolved_uris!(connection_opts)
          connection_opts[:preconnect] = false if adapter != :sqlite && dev_fallback?
          connection_opts
        end

        def validate_no_unresolved_uris!(connection_opts)
          %i[user username password].each do |key|
            value = connection_opts[key]
            next unless value.is_a?(String) && value.match?(UNRESOLVED_URI_PATTERN)

            raise UnresolvedCredentialError,
                  "Legion::Data cannot connect: settings[:data][:creds][:#{key}] is still " \
                  "an unresolved URI placeholder (#{value}). The settings resolver failed to " \
                  'resolve this lease — check that Legion::Crypt and Vault are available at boot.'
          end
        end

        def sequel_opts
          data = Legion::Settings[:data]
          opts = {}

          # Generic pool options
          GENERIC_KEYS.each do |key|
            val = data[key]
            opts[key] = val unless val.nil?
          end

          # Query log mode: all queries to dedicated file, isolated from main domain
          if data[:query_log]
            log_path = File.join(QUERY_LOG_DIR, 'data-shared-query.log')
            @query_file_logger = QueryFileLogger.new(log_path)
            opts[:logger]              = @query_file_logger
            opts[:sql_log_level]       = :debug
            opts[:log_connection_info] = data[:log_connection_info] || false
          elsif data[:log]
            # Standard mode: slow-query warnings through Legion::Logging domain
            opts[:logger]              = build_data_logger
            opts[:sql_log_level]       = data[:sql_log_level]&.to_sym || :debug
            opts[:log_warn_duration]   = data[:log_warn_duration]
            opts[:log_connection_info] = data[:log_connection_info] || false
          end

          # Adapter-specific: user setting wins, then built-in default, skip if nil
          defaults = ADAPTER_DEFAULTS.fetch(adapter, {})
          ADAPTER_KEYS.fetch(adapter, []).each do |key|
            val = data.key?(key) && !data[key].nil? ? data[key] : defaults[key]
            opts[key] = val unless val.nil?
          end

          opts
        end

        def tuning_stats(data)
          tuning = {}

          # Pool tuning
          GENERIC_KEYS.each { |key| tuning[key] = data[key] }

          # Logging
          tuning[:log]                 = data[:log]
          tuning[:query_log]           = data[:query_log]
          tuning[:query_log_path]      = @query_file_logger&.path
          tuning[:log_warn_duration]   = data[:log_warn_duration]
          tuning[:sql_log_level]       = data[:sql_log_level]
          tuning[:log_connection_info] = data[:log_connection_info]

          # Connection health
          tuning[:connection_validation] = data[:connection_validation]
          tuning[:connection_validation_timeout]  = data[:connection_validation_timeout]
          tuning[:connection_expiration]          = data[:connection_expiration]
          tuning[:connection_expiration_timeout]  = data[:connection_expiration_timeout]

          # Adapter-specific (only keys relevant to current adapter)
          defaults = ADAPTER_DEFAULTS.fetch(adapter, {})
          ADAPTER_KEYS.fetch(adapter, []).each do |key|
            tuning[key] = data.key?(key) && !data[key].nil? ? data[key] : defaults[key]
          end

          tuning
        end

        def database_stats
          case adapter
          when :sqlite   then sqlite_stats
          when :postgres then postgres_stats
          when :mysql2   then mysql_stats
          else {}
          end
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: true, operation: :data_database_stats, adapter: adapter)
          { error: e.message }
        end

        def sqlite_stats
          db = @sequel
          stats = {}
          %w[page_size page_count freelist_count journal_mode wal_autocheckpoint
             cache_size busy_timeout].each do |pragma|
            val = begin
              db.fetch("PRAGMA #{pragma}").single_value
            rescue StandardError => e
              handle_exception(e, level: :warn, handled: true, operation: :sqlite_stats_pragma, pragma: pragma)
              nil
            end
            stats[pragma.to_sym] = val unless val.nil?
          end

          db_path = Legion::Settings[:data][:creds][:database] || 'legionio.db'
          stats[:file_size] = File.size(db_path) if File.exist?(db_path)
          stats[:database_size_bytes] = (stats[:page_size].to_i * stats[:page_count].to_i) if stats[:page_size] && stats[:page_count]
          stats
        end

        def postgres_stats
          db = @sequel
          stats = {}

          row = db.fetch('SELECT current_database() AS db, pg_database_size(current_database()) AS size_bytes').first
          stats[:database_name]       = row[:db]
          stats[:database_size_bytes] = row[:size_bytes]

          activity = db.fetch(<<~SQL).first
            SELECT
              count(*) FILTER (WHERE state = 'active') AS active,
              count(*) FILTER (WHERE state = 'idle') AS idle,
              count(*) FILTER (WHERE state = 'idle in transaction') AS idle_in_transaction,
              count(*) AS total
            FROM pg_stat_activity
            WHERE datname = current_database()
          SQL
          stats[:server_connections] = activity

          settings = db.fetch(<<~SQL).first
            SELECT
              current_setting('max_connections')::int AS max_connections,
              current_setting('shared_buffers') AS shared_buffers,
              current_setting('work_mem') AS work_mem,
              current_setting('server_version') AS server_version
          SQL
          stats[:server] = settings

          stats
        end

        def mysql_stats
          db = @sequel
          stats = {}

          size_row = db.fetch(<<~SQL).first
            SELECT SUM(data_length + index_length) AS size_bytes
            FROM information_schema.tables
            WHERE table_schema = DATABASE()
          SQL
          stats[:database_name]       = db.fetch('SELECT DATABASE() AS db').single_value
          stats[:database_size_bytes] = size_row[:size_bytes]&.to_i

          threads = {}
          db.fetch("SHOW STATUS WHERE Variable_name IN ('Threads_connected','Threads_running','Max_used_connections')").each do |row|
            threads[row[:Variable_name].downcase.to_sym] = row[:Value].to_i
          end
          stats[:server_connections] = threads

          max_conn = db.fetch("SHOW VARIABLES LIKE 'max_connections'").first
          version  = db.fetch('SELECT VERSION() AS v').single_value
          stats[:server] = {
            max_connections: max_conn ? max_conn[:Value].to_i : nil,
            server_version:  version
          }

          stats
        end

        def configure_extensions
          return if adapter == :sqlite

          data = Legion::Settings[:data]

          if adapter == :postgres
            Sequel.extension(:pg_array)
            @sequel.extension(:pg_array)
          end

          if data[:connection_validation] != false
            @sequel.extension(:connection_validator)
            @sequel.pool.connection_validation_timeout = data[:connection_validation_timeout]
          end

          if data[:connection_expiration] != false
            @sequel.extension(:connection_expiration)
            @sequel.pool.connection_expiration_timeout = data[:connection_expiration_timeout]
          end

          install_auth_failure_hook
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: true, operation: :configure_extensions, adapter: adapter)
        end

        def install_auth_failure_hook
          Legion::Data::AuthFailureHandler.install(@sequel)
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: true, operation: :install_auth_failure_hook)
        end

        def build_data_logger
          tagged = if defined?(Legion::Logging::TaggedLogger) && respond_to?(:tagged_logger_settings, true)
                     Legion::Logging::TaggedLogger.new(
                       segments: %w[data connection],
                       **send(:tagged_logger_settings)
                     )
                   else
                     SegmentedTaggedLogger.new(segments: %w[data connection])
                   end
          SlowQueryLogger.new(tagged)
        rescue StandardError => e
          if respond_to?(:handle_exception, true)
            handle_exception(e, level: :warn, handled: true, operation: :build_data_logger)
          else
            log.warn("build_data_logger failed: #{e.class}: #{e.message}")
          end
          SlowQueryLogger.new(SegmentedTaggedLogger.new(segments: %w[data connection], logger: log))
        end
      end
    end
  end
end
