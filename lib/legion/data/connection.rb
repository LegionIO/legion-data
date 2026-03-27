# frozen_string_literal: true

require 'fileutils'
require 'sequel'

module Legion
  module Data
    module Connection
      ADAPTERS = %i[sqlite mysql2 postgres].freeze

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

      # File-based query logger that writes all SQL to a dedicated log file.
      # Isolated from the main Legion::Logging domain.
      class QueryFileLogger
        attr_reader :path

        def initialize(path)
          @path = path
          dir = File.dirname(path)
          FileUtils.mkdir_p(dir)
          FileUtils.chmod(0o700, dir) if File.directory?(dir)
          @file = File.open(path, File::WRONLY | File::APPEND | File::CREAT, 0o600)
          @file.sync = true
          @mutex = Mutex.new
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
          @mutex.synchronize { @file.close unless @file.closed? }
        end

        private

        def write(level, message)
          @mutex.synchronize do
            @file.puts "[#{Time.now.strftime('%Y-%m-%d %H:%M:%S.%L')}] #{level} #{message}"
          end
        rescue IOError
          nil
        end
      end

      class << self
        attr_accessor :sequel

        def adapter
          @adapter ||= Legion::Settings[:data][:adapter]&.to_sym || :sqlite
        end

        def setup
          opts = sequel_opts
          @sequel = if adapter == :sqlite
                      ::Sequel.connect(opts.merge(adapter: :sqlite, database: sqlite_path))
                    else
                      begin
                        ::Sequel.connect(opts.merge(adapter: adapter, **creds_builder))
                      rescue StandardError => e
                        raise unless dev_fallback?

                        if defined?(Legion::Logging)
                          Legion::Logging.warn(
                            "Shared DB unreachable (#{e.message}), dev_mode fallback to SQLite"
                          )
                        end
                        @adapter = :sqlite
                        sqlite_opts = sequel_opts
                        ::Sequel.connect(sqlite_opts.merge(adapter: :sqlite, database: sqlite_path))
                      end
                    end
          Legion::Settings[:data][:connected] = true
          if defined?(Legion::Logging)
            if adapter == :sqlite
              Legion::Logging.info "Connected to SQLite at #{sqlite_path}"
            else
              creds = Legion::Data::Settings.creds(adapter)
              user = creds[:user] || creds[:username] || 'unknown'
              host = creds[:host] || '127.0.0.1'
              port = creds[:port]
              db   = creds[:database] || creds[:db]
              Legion::Logging.info "Connected to #{adapter}://#{user}@#{host}:#{port}/#{db}"
            end
          end
          configure_extensions
          connect_with_replicas
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
        rescue StandardError
          {}
        end

        def shutdown
          @sequel&.disconnect
          @query_file_logger&.close
          @query_file_logger = nil
          Legion::Settings[:data][:connected] = false
          Legion::Logging.info 'Legion::Data connection closed' if defined?(Legion::Logging)
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
          Legion::Logging.debug "Registered #{@replica_servers.size} read replica(s)" if defined?(Legion::Logging)
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
          Legion::Logging.debug("Connection#data_tls_settings failed: #{e.message}") if defined?(Legion::Logging)
          {}
        end

        def dev_fallback?
          data_settings = Legion::Settings[:data]
          data_settings[:dev_mode] == true && data_settings[:dev_fallback] != false
        end

        def sqlite_path
          Legion::Settings[:data][:creds][:database] || 'legionio.db'
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
          elsif data[:log] && defined?(Legion::Logging)
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
          { error: e.message }
        end

        def sqlite_stats
          db = @sequel
          stats = {}
          %w[page_size page_count freelist_count journal_mode wal_autocheckpoint
             cache_size busy_timeout].each do |pragma|
            val = begin
              db.fetch("PRAGMA #{pragma}").single_value
            rescue StandardError
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
            @sequel.pool.connection_validation_timeout = data[:connection_validation_timeout] || 600
          end

          if data[:connection_expiration] != false
            @sequel.extension(:connection_expiration)
            @sequel.pool.connection_expiration_timeout = data[:connection_expiration_timeout] || 14_400
          end
        rescue StandardError => e
          Legion::Logging.warn "Failed to load connection extensions: #{e.message}" if defined?(Legion::Logging)
        end

        def build_data_logger
          tagged = Legion::Logging::Logger.new(lex: 'data')
          SlowQueryLogger.new(tagged)
        end
      end
    end
  end
end
