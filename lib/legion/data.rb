# frozen_string_literal: true

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

module Legion
  module Data
    class << self
      def setup
        connection_setup
        migrate
        load_models
        setup_cache
        setup_local
        Legion::Logging.info 'Legion::Data setup complete' if defined?(Legion::Logging)
      end

      def connection_setup
        return if Legion::Settings[:data][:connected]

        Legion::Data::Connection.setup
      end

      def migrate
        Legion::Data::Migration.migrate
      end

      def load_models
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

      def setup_cache
        cache_settings = Legion::Settings[:data][:cache]
        setup_static_cache if cache_settings[:static_cache]
        setup_external_cache if cache_settings[:auto_enable] && defined?(::Legion::Cache)
      end

      def setup_static_cache
        [Model::Extension, Model::Runner, Model::Function].each do |model|
          model.plugin :static_cache
          Legion::Logging.debug("StaticCache enabled for #{model}") if defined?(Legion::Logging)
        rescue StandardError => e
          Legion::Logging.warn("StaticCache failed for #{model}: #{e.message}") if defined?(Legion::Logging)
        end
        Legion::Logging.info 'Legion::Data static cache loaded' if defined?(Legion::Logging)
      end

      def reload_static_cache
        [Model::Extension, Model::Runner, Model::Function].each do |model|
          model.load_cache if model.respond_to?(:load_cache)
        end
      end

      def setup_external_cache
        ttl = Legion::Settings[:data][:cache][:ttl] || 60
        {
          Model::Relationship => 10,
          Model::Node         => 10,
          Model::Setting      => ttl
        }.each do |model, model_ttl|
          model.plugin :caching, ::Legion::Cache, ttl: model_ttl
          Legion::Logging.debug("Caching enabled for #{model} (ttl: #{model_ttl})") if defined?(Legion::Logging)
        rescue StandardError => e
          Legion::Logging.warn("Caching failed for #{model}: #{e.message}") if defined?(Legion::Logging)
        end
        Legion::Logging.info 'Legion::Data external cache connected' if defined?(Legion::Logging)
      end

      def shutdown
        Legion::Data::Local.shutdown if defined?(Legion::Data::Local) && Legion::Data::Local.connected?
        Legion::Data::Connection.shutdown
        Legion::Logging.info 'Legion::Data shutdown complete' if defined?(Legion::Logging)
      end

      private

      def setup_local
        return if Legion::Settings[:data].dig(:local, :enabled) == false

        Legion::Data::Local.setup
      rescue StandardError => e
        Legion::Logging.warn "Legion::Data::Local failed to setup: #{e.message}" if defined?(Legion::Logging)
      end
    end
  end
end
