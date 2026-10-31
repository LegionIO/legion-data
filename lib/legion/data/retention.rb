# frozen_string_literal: true

require 'legion/logging/helper'
require_relative 'archival/policy'

module Legion
  module Data
    module Retention
      DEFAULT_RETENTION_YEARS = 7
      DEFAULT_ARCHIVE_AFTER_DAYS = 90

      class << self
        include Legion::Logging::Helper

        def archive_old_records(table:, date_column: nil, archive_after_days: DEFAULT_ARCHIVE_AFTER_DAYS, batch_size: 1000)
          db = Legion::Data.connection
          return { archived: 0, table: table } unless db
          raise ArgumentError, 'batch_size must be a positive Integer' unless batch_size.is_a?(Integer) && batch_size.positive?

          date_column = resolve_date_column(table, date_column)
          cutoff = Time.now - (archive_after_days * 86_400)
          archive_table = archive_table_name(table)
          primary_keys = db.schema(table).filter_map { |name, info| name if info[:primary_key] }
          raise Sequel::Error, "#{table} needs a primary key for bounded retention" if primary_keys.empty?

          ensure_archive_table!(db, table, archive_table)

          count = 0
          loop do
            archived = db.transaction(savepoint: true, **(db.database_type == :sqlite ? { mode: :immediate } : {})) do
              records = db[table].where(Sequel.identifier(date_column) < cutoff).order(*primary_keys).limit(batch_size)
              records = records.where(execution_key: nil) if table.to_sym == :tasks
              records = records.for_update unless db.database_type == :sqlite
              rows = records.all
              next 0 if rows.empty?

              db[archive_table].multi_insert(rows)
              deleted = delete_archived_rows(db: db, table: table, rows: rows, primary_keys: primary_keys)
              raise Sequel::Error, "Retention copied #{rows.length} rows but deleted #{deleted} from #{table}" unless deleted == rows.length

              deleted
            end
            break if archived.zero?

            count += archived
          end

          log.info "Archived #{count} row(s) from #{table}" if count.positive?
          { archived: count, table: table }
        rescue StandardError => e
          handle_exception(
            e,
            level:              :error,
            handled:            false,
            operation:          :archive_old_records,
            table:              table,
            date_column:        date_column,
            archive_after_days: archive_after_days
          )
          raise
        end

        def purge_expired_records(table:, date_column: nil, retention_years: DEFAULT_RETENTION_YEARS)
          db = Legion::Data.connection
          archive_table = archive_table_name(table)
          return { purged: 0, table: table } unless db&.table_exists?(archive_table)

          date_column = resolve_date_column(table, date_column)
          cutoff = Time.now - (retention_years * 365 * 86_400)
          expired = db[archive_table].where(Sequel.identifier(date_column) < cutoff)
          count = expired.count
          expired.delete if count.positive?
          log.info "Purged #{count} expired row(s) from #{archive_table}" if count.positive?

          { purged: count, table: table }
        rescue StandardError => e
          handle_exception(
            e,
            level:           :error,
            handled:         false,
            operation:       :purge_expired_records,
            table:           table,
            date_column:     date_column,
            retention_years: retention_years
          )
          raise
        end

        def retention_status(table:, date_column: nil)
          db = Legion::Data.connection
          archive_table = archive_table_name(table)
          date_column = resolve_date_column(table, date_column)

          active_count = db&.table_exists?(table) ? db[table].count : 0
          archived_count = db&.table_exists?(archive_table) ? db[archive_table].count : 0

          oldest_active = (db[table].order(Sequel.asc(date_column)).get(date_column) if db&.table_exists?(table) && active_count.positive?)

          oldest_archived = (db[archive_table].order(Sequel.asc(date_column)).get(date_column) if db&.table_exists?(archive_table) && archived_count.positive?)

          {
            table:           table,
            active_count:    active_count,
            archived_count:  archived_count,
            oldest_active:   oldest_active,
            oldest_archived: oldest_archived
          }
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: false, operation: :retention_status, table: table, date_column: date_column)
          raise
        end

        def archive_table_name(table)
          :"#{table}_archive"
        end

        private

        def resolve_date_column(table, date_column)
          return date_column if date_column

          if defined?(Legion::Data::Archival::Policy::DATE_COLUMN_OVERRIDES)
            Legion::Data::Archival::Policy::DATE_COLUMN_OVERRIDES[table.to_s] || :created_at
          else
            :created_at
          end
        end

        def delete_archived_rows(db:, table:, rows:, primary_keys:)
          if primary_keys.one?
            key = primary_keys.first
            return db[table].where(key => rows.map { |row| row.fetch(key) }).delete
          end

          # SQLite expands composite-key predicates into OR expressions with a depth limit.
          identity_batch_size = db.database_type == :sqlite ? 100 : rows.length
          rows.each_slice(identity_batch_size).sum do |batch|
            db[table].where(primary_keys => batch.map { |row| row.values_at(*primary_keys) }).delete
          end
        end

        def ensure_archive_table!(db, source_table, archive_table)
          return if db.table_exists?(archive_table)

          source_schema = db.schema(source_table).to_h

          log.info "Creating archive table #{archive_table} from #{source_table}"
          db.transaction(savepoint: true) do
            db.create_table?(archive_table) do
              source_schema.each do |col_name, col_info|
                column col_name, col_info[:db_type]
              end
              DateTime :archived_at, default: Sequel::CURRENT_TIMESTAMP
            end
          end
        rescue Sequel::UniqueConstraintViolation => e
          raise unless db.table_exists?(archive_table)

          handle_exception(e, level: :debug, handled: true, operation: :concurrent_archive_creation, table: archive_table)
        end
      end
    end
  end
end
