# frozen_string_literal: true

require 'legion/logging/helper'
require 'legion/data/version'
require 'legion/data/settings'
require 'sequel'

require 'legion/data/connection'
require 'legion/data/model'
require 'legion/data/migration'
require_relative 'data/local'
require_relative 'data/spool'
require_relative 'data/partition_manager'
require_relative 'data/archiver'
require_relative 'data/helper'
require_relative 'data/rls'
require_relative 'data/extract'
require_relative 'data/audit_record'
require_relative 'data/audit_log_hash_chain'
require_relative 'data/task_execution'

unless Legion::Logging::Helper.method_defined?(:handle_exception)
  module Legion
    module Logging
      module Helper
        def handle_exception(exception, task_id: nil, level: :error, handled: true, **opts)
          context = opts.map { |key, value| "#{key}=#{value.inspect}" }.join(' ')
          message = "#{exception.class}: #{exception.message}"
          message = "#{message} task_id=#{task_id}" if task_id
          message = "#{message} handled=#{handled}"
          message = "#{message} #{context}" unless context.empty?
          warn("[#{level}] #{message}")
        rescue StandardError => e
          warn("handle_exception fallback failed: #{e.class}: #{e.message}")
        end
      end
    end
  end
end

module Legion
  module Data
    class << self
      include Legion::Logging::Helper

      def setup
        log.info 'Legion::Data setup starting'
        setup_global
        setup_cache
        setup_local
        log.info 'Legion::Data setup complete'
      rescue StandardError, LoadError => e
        shutdown
        Legion::Data::Connection.sequel = nil
        handle_exception(e, level: :fatal, handled: false, operation: :setup)
        raise
      end

      def setup_local
        return if Legion::Settings[:data].dig(:local, :enabled) == false

        Legion::Data::Local.setup
        log.info "Legion::Data::Local connected to #{Legion::Data::Local.db_path}"
      rescue StandardError => e
        handle_exception(e, level: :fatal, operation: :setup_local)
        raise
      end

      def setup_global
        connection_setup
        Legion::Settings[:data][:connected] = false
        Legion::Settings[:data][:migrations][:ran] = false
        Legion::Settings[:data][:models][:loaded] = false
        migrate
        load_models
        Legion::Settings[:data][:connected] = true
      rescue StandardError, LoadError => e
        Legion::Data::Connection.shutdown
        Legion::Data::Connection.sequel = nil
        Legion::Settings[:data][:migrations][:ran] = false
        Legion::Settings[:data][:models][:loaded] = false
        handle_exception(e, level: :fatal, handled: false, operation: :setup_global)
        raise
      end

      def setup_cache
        cache_settings = Legion::Settings[:data][:cache]
        setup_static_cache if cache_settings[:static_cache]
        setup_external_cache if cache_settings[:auto_enable] && defined?(::Legion::Cache)
      rescue StandardError => e
        handle_exception(e, level: :error, operation: :setup_cache)
      end

      def connection_setup
        return if Legion::Settings[:data][:connected]

        Legion::Data::Connection.setup
      end

      def migrate
        return if skip_migrations?

        Legion::Data::Migration.migrate
      end

      def load_models
        return unless Legion::Settings[:data][:models][:autoload] != false

        Legion::Data::Models.load
      end

      def connection
        Legion::Data::Connection.sequel
      end

      def local
        Legion::Data::Local
      end

      def stats
        {
          shared: Legion::Data::Connection.stats,
          local:  Legion::Data::Local.stats
        }
      end

      def connected?
        Legion::Settings[:data][:connected] == true
      rescue StandardError => e
        handle_exception(e, level: :warn, handled: true, operation: :connected?)
        false
      end

      def can_write?(table_name)
        return false unless connected?

        database = connection
        return false unless database
        return true if database.database_type == :sqlite

        cache = @write_privileges ||= ObjectSpace::WeakKeyMap.new
        database.synchronize do |session|
          privileges = cache[session] ||= {}
          return privileges[table_name] if privileges.key?(table_name)

          privileges[table_name] = case database.database_type
                                   when :postgres
                                     database.fetch("SELECT has_table_privilege(current_user, ?, 'INSERT') AS can", table_name.to_s)
                                             .server(:default).first[:can] == true
                                   when :mysql
                                     database.fetch('EXPLAIN INSERT INTO ? () VALUES ()', Sequel.identifier(table_name)).server(:default).all
                                     true
                                   else
                                     raise Sequel::Error, "Unsupported privilege adapter: #{database.database_type}"
                                   end
        end
      rescue StandardError => e
        handle_exception(e, level: :warn, handled: true, operation: :can_write?, table: table_name)
        false
      end

      def can_read?(table_name)
        return false unless connected?

        database = connection
        return false unless database
        return true if database.database_type == :sqlite

        cache = @read_privileges ||= ObjectSpace::WeakKeyMap.new
        database.synchronize do |session|
          privileges = cache[session] ||= {}
          return privileges[table_name] if privileges.key?(table_name)

          privileges[table_name] = case database.database_type
                                   when :postgres
                                     database.fetch("SELECT has_table_privilege(current_user, ?, 'SELECT') AS can", table_name.to_s)
                                             .server(:default).first[:can] == true
                                   when :mysql
                                     database.fetch('SELECT * FROM ? LIMIT 0', Sequel.identifier(table_name)).server(:default).all
                                     true
                                   else
                                     raise Sequel::Error, "Unsupported privilege adapter: #{database.database_type}"
                                   end
        end
      rescue StandardError => e
        handle_exception(e, level: :warn, handled: true, operation: :can_read?, table: table_name)
        false
      end

      def reset_privileges!
        @write_privileges = nil
        @read_privileges = nil
      end

      def setup_static_cache
        [Model::Extension, Model::Runner, Model::Function].each do |model|
          model.plugin :static_cache
          log.debug("StaticCache enabled for #{model}")
        rescue StandardError => e
          handle_exception(e, level: :warn, operation: :setup_static_cache, model: model.to_s)
        end
        log.info 'Legion::Data static cache loaded'
      end

      def reload_static_cache
        [Model::Extension, Model::Runner, Model::Function].each do |model|
          model.load_cache if model.respond_to?(:load_cache)
        end
        log.info 'Legion::Data static cache reloaded'
      end

      def setup_external_cache
        ttl = Legion::Settings[:data][:cache][:ttl] || 60
        {
          Model::Relationship => 10,
          Model::Node         => 10,
          Model::Setting      => ttl
        }.each do |model, model_ttl|
          model.plugin :caching, ::Legion::Cache, ttl: model_ttl
          log.debug("Caching enabled for #{model} (ttl: #{model_ttl})")
        rescue StandardError => e
          handle_exception(e, level: :warn, operation: :setup_external_cache, model: model.to_s, ttl: model_ttl)
        end
        log.info 'Legion::Data external cache connected'
      end

      def shutdown
        Legion::Data::Local.shutdown if defined?(Legion::Data::Local) && Legion::Data::Local.connected?
        closed = Legion::Data::Connection.shutdown
        log.info 'Legion::Data shutdown complete' if closed
        closed
      end

      private

      def skip_migrations?
        # Check auto_migrate setting
        auto_migrate = Legion::Settings[:data][:migrations][:auto_migrate]
        unless auto_migrate
          log.info 'Legion::Data migrations skipped (auto_migrate: false)'
          return true
        end

        # Check mode gate: only infra mode runs migrations (when Mode is available)
        if defined?(Legion::Mode) && Legion::Mode.respond_to?(:current) && !Legion::Mode.infra?
          log.info "Legion::Data migrations skipped (mode: #{Legion::Mode.current}, requires: infra)"
          return true
        end

        false
      end
    end
  end
end
