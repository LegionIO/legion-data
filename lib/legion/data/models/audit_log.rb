# frozen_string_literal: true

require 'legion/logging/helper'
require 'legion/data/audit_log_hash_chain'

module Legion
  module Data
    module Model
      class AuditLog < Sequel::Model(:audit_log)
        include Legion::Logging::Helper
        extend Legion::Logging::Helper

        VALID_EVENT_TYPES = %w[runner_execution lifecycle_transition].freeze
        VALID_STATUSES    = %w[success failure denied].freeze
        HASH_CHAIN_COLUMNS = [:id, :record_hash, *Legion::Data::AuditLogHashChain::CANONICAL_FIELDS].freeze

        def validate
          super
          errors.add(:event_type, 'invalid') unless VALID_EVENT_TYPES.include?(event_type)
          errors.add(:status, 'invalid')     unless VALID_STATUSES.include?(status)
        end

        def parsed_detail
          return nil unless detail

          Legion::JSON.load(detail)
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: true, operation: :parsed_detail, id: self[:id])
          nil
        end

        def before_update
          raise 'audit_log records are immutable and cannot be updated'
        end

        def before_destroy
          raise 'audit_log records are immutable and cannot be deleted'
        end

        def self.compute_hash(record)
          Legion::Data::AuditLogHashChain.compute_hash(record)
        end

        def self.verify_chain(records = nil)
          return Legion::Data::AuditLogHashChain.verify(records) unless records.nil?

          hot = dataset.naked.select(*HASH_CHAIN_COLUMNS)
          unless audit_archive_exists?
            result = Legion::Data::AuditLogHashChain.verify(hot.order(:created_at, :id))
            # Retention may create the archive and move rows after the first presence check.
            return result unless audit_archive_exists?
          end

          warm = db[:audit_log_archive].select(*HASH_CHAIN_COLUMNS)
          Legion::Data::AuditLogHashChain.verify(hot.union(warm, all: true).order(:created_at, :id))
        end

        def self.audit_archive_exists?
          db.transaction(savepoint: :only) { db[:audit_log_archive].get(Sequel::NULL) }
          true
        rescue Sequel::DatabaseError => e
          cause = e.wrapped_exception
          missing = case db.database_type
                    when :postgres
                      cause.is_a?(::PG::UndefinedTable)
                    when :mysql
                      cause.respond_to?(:error_number) && cause.error_number == 1146
                    when :sqlite
                      cause.is_a?(::SQLite3::SQLException) && cause.message.start_with?('no such table: audit_log_archive')
                    end
          raise unless missing

          handle_exception(e, level: :debug, handled: true, operation: :audit_archive_presence)
          false
        end
        private_class_method :audit_archive_exists?
      end
    end
  end
end
