# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module Data
    module Helper
      include Legion::Logging::Helper

      def data_path
        @data_path ||= "#{full_path}/data"
      end

      def data_class
        @data_class ||= lex_class::Data
      end

      def models_class
        @models_class ||= data_class::Model
      end

      def data_connected?
        Legion::Settings[:data][:connected]
      end

      def data_connection
        Legion::Data::Connection.sequel
      end

      def local_data_connected?
        Legion::Data::Local.connected?
      end

      def local_data_connection
        Legion::Data::Local.connection
      end

      def local_data_model(table_name)
        Legion::Data::Local.model(table_name)
      end

      # --- Pool / Resource Info ---

      def data_adapter
        Legion::Data::Connection.adapter
      rescue StandardError => e
        handle_exception(e, level: :warn, handled: true, operation: :data_adapter)
        :unknown
      end

      def data_pool_stats
        return {} unless data_connected?

        Legion::Data::Connection.pool_stats
      rescue StandardError => e
        handle_exception(e, level: :warn, handled: true, operation: :data_pool_stats)
        {}
      end

      def data_stats
        return {} unless data_connected?

        Legion::Data.stats
      rescue StandardError => e
        handle_exception(e, level: :warn, handled: true, operation: :data_stats)
        {}
      end

      def local_data_stats
        return {} unless local_data_connected?

        Legion::Data::Local.stats
      rescue StandardError => e
        handle_exception(e, level: :warn, handled: true, operation: :local_data_stats)
        {}
      end

      # --- Permission Helpers ---

      def data_can_read?(table_name)
        Legion::Data.can_read?(table_name)
      rescue StandardError => e
        handle_exception(e, level: :warn, handled: true, operation: :data_can_read, table: table_name)
        false
      end

      def data_can_write?(table_name)
        Legion::Data.can_write?(table_name)
      rescue StandardError => e
        handle_exception(e, level: :warn, handled: true, operation: :data_can_write, table: table_name)
        false
      end
    end
  end
end
