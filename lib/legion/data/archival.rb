# frozen_string_literal: true

require 'legion/logging/helper'
require_relative 'archival/policy'

module Legion
  module Data
    module Archival
      ARCHIVE_TABLE_MAP = {
        tasks:            :tasks_archive,
        metering_records: :metering_records_archive
      }.freeze
      COLUMN_MAP = { id: :original_id, created_at: :original_created_at, updated_at: :original_updated_at }.freeze
      TASK_COLUMN_MAP = {
        id: :original_id, created: :original_created_at, updated: :original_updated_at,
        function_args: :args, results: :result
      }.freeze

      class << self
        include Legion::Logging::Helper

        def archive!(policy: Policy.new, dry_run: false)
          log.info "Archival run started dry_run=#{dry_run} tables=#{policy.tables.size}"
          results = {}
          policy.tables.each do |table_name|
            table = table_name.to_sym
            archive_table = ARCHIVE_TABLE_MAP[table]
            next unless archive_table && db_ready?(table) && db_ready?(archive_table)

            log.info "Archiving #{table} -> #{archive_table} (cutoff: #{policy.warm_cutoff}, dry_run: #{dry_run})"
            count = archive_table!(
              source: table, destination: archive_table,
              cutoff: policy.warm_cutoff, batch_size: policy.batch_size, dry_run: dry_run
            )
            results[table] = count
          end
          log.info "Archival run completed tables=#{results.keys.join(',')}" unless results.empty?
          results
        rescue StandardError => e
          handle_exception(e, level: :error, handled: false, operation: :archive!, dry_run: dry_run)
          raise
        end

        def restore(table:, ids:)
          source_table = table.to_sym
          archive_table = ARCHIVE_TABLE_MAP[source_table]
          return 0 unless archive_table && db_ready?(archive_table)

          conn = Legion::Data.connection
          restored = conn.transaction(savepoint: true, **(conn.database_type == :sqlite ? { mode: :immediate } : {})) do
            dataset = conn[archive_table].where(original_id: ids).order(:original_id)
            dataset = dataset.for_update unless conn.database_type == :sqlite
            archived = dataset.all
            rows = restore_row_values(conn: conn, source: source_table, archived: archived)
            rows.each do |row|
              conn[source_table].insert(source_table == :tasks ? row.merge(parent_id: nil, master_id: nil) : row)
            end
            rows.each { |row| conn[:tasks].where(id: row[:id]).update(row.slice(:parent_id, :master_id)) } if source_table == :tasks
            conn[archive_table].where(id: archived.map { |row| row[:id] }).delete
            rows.size
          end
          log.info "Restored #{restored} row(s) from #{archive_table} -> #{source_table}"
          restored
        rescue StandardError => e
          handle_exception(e, level: :error, handled: false, operation: :restore, table: source_table, ids: Array(ids))
          raise
        end

        def search(table:, where: {})
          source_table = table.to_sym
          archive_table = ARCHIVE_TABLE_MAP[source_table]
          return [] unless db_ready?(source_table)

          log.info "Archival search table=#{source_table} where_keys=#{where.keys.join(',')}"
          conn = Legion::Data.connection
          hot = conn[source_table].where(where).all
          warm = db_ready?(archive_table) ? conn[archive_table].where(where).all : []
          hot + warm
        rescue StandardError => e
          handle_exception(e, level: :error, handled: false, operation: :search, table: source_table, where_keys: where.keys)
          raise
        end

        def archive_completed_tasks(days_old: 90, batch_size: 1000)
          conn = Legion::Data.connection
          cutoff = Time.now - (days_old * 86_400)

          return { archived: 0, cutoff: cutoff.iso8601 } unless conn&.table_exists?(:tasks) && conn.table_exists?(:tasks_archive)

          count = archive_table!(source: :tasks, destination: :tasks_archive, cutoff: cutoff,
                                 batch_size: batch_size, dry_run: false, statuses: %w[completed failed])

          log.info "archive_completed_tasks: archived #{count} tasks (cutoff: #{cutoff.iso8601})"
          { archived: count, cutoff: cutoff.iso8601 }
        rescue StandardError => e
          handle_exception(e, level: :error, handled: false, operation: :archive_completed_tasks, days_old: days_old, batch_size: batch_size)
          raise
        end

        def run_scheduled_archival
          log.info 'Running scheduled archival'
          results = {}
          results[:tasks] = archive_completed_tasks

          conn = Legion::Data.connection
          if conn&.table_exists?(:metering_records)
            results[:metering] = Legion::Data::Retention.archive_old_records(
              table: :metering_records, date_column: :recorded_at
            )
          end

          log.info "Scheduled archival completed keys=#{results.keys.join(',')}"
          results
        rescue StandardError => e
          handle_exception(e, level: :error, handled: false, operation: :run_scheduled_archival)
          raise
        end

        private

        def archive_table!(source:, destination:, cutoff:, batch_size:, dry_run:, statuses: nil)
          conn = Legion::Data.connection
          date_column = Policy::DATE_COLUMN_OVERRIDES.fetch(source.to_s, :created_at)
          candidates = conn[source].where(Sequel[date_column] < cutoff).order(:id).limit(batch_size)
          candidates = candidates.where(status: statuses) if statuses
          if source == :tasks
            candidates = candidates.where(execution_key: nil)
            references = conn.from(Sequel.as(:tasks, :dependent_tasks))
                             .where(Sequel.|({ parent_id: Sequel[:tasks][:id] }, { master_id: Sequel[:tasks][:id] }))
                             .exclude(id: Sequel[:tasks][:id]).exists
            candidates = candidates.exclude(references)
          end
          return candidates.count if dry_run

          mapping = source == :tasks ? TASK_COLUMN_MAP : COLUMN_MAP
          conn.transaction(savepoint: true, **(conn.database_type == :sqlite ? { mode: :immediate } : {})) do
            locked = conn.database_type == :sqlite ? candidates : candidates.for_update
            selected_ids = locked.select_map(:id)
            selected = conn[source].where(id: selected_ids).order(:id)
            selected = selected.where(execution_key: nil).exclude(references) if source == :tasks
            selected = selected.for_update unless conn.database_type == :sqlite
            rows = selected.all
            rows.each do |row|
              archive_row = row.to_h { |column, value| [mapping.fetch(column, column), value] }
              conn[destination].insert(archive_row.merge(archived_at: Time.now))
            end
            conn[source].where(id: rows.map { |row| row[:id] }).delete
            rows.size
          end
        end

        def restore_row_values(conn:, source:, archived:)
          mapping = source == :tasks ? TASK_COLUMN_MAP : COLUMN_MAP
          columns = conn.schema(source).reject { |_, info| info[:generated] }.map(&:first)
          archived.map { |row| columns.to_h { |column| [column, row[mapping.fetch(column, column)]] } }
        end

        def db_ready?(table)
          defined?(Legion::Data) && Legion::Data.connection&.table_exists?(table)
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: true, operation: :archival_db_ready, table: table)
          false
        end
      end
    end
  end
end
