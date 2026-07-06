# frozen_string_literal: true

require 'legion/logging/helper'
require 'digest'
require 'fileutils'
require 'json'
require 'securerandom'
require 'tmpdir'
require 'zlib'

module Legion
  module Data
    module Archiver
      class UploadError < StandardError; end

      class << self
        include Legion::Logging::Helper

        def archive_table(table:, retention_days: 90, batch_size: 1000, storage_backend: nil)
          return { skipped: true, reason: 'not_postgres' } unless postgres?

          log.info "Archiving table #{table} (retention: #{retention_days}d)"

          conn = Legion::Data.connection
          cutoff = Time.now - (retention_days * 86_400)
          archive_results = archive_batches(
            conn:            conn,
            table:           table,
            cutoff:          cutoff,
            batch_size:      batch_size,
            storage_backend: storage_backend
          )

          log.info "Archived #{archive_results[:total_rows]} rows from #{table} in #{archive_results[:batches]} batch(es)"
          archive_results
        rescue StandardError => e
          handle_exception(
            e,
            level:           :error,
            handled:         false,
            operation:       :archive_table,
            table:           table,
            retention_days:  retention_days,
            batch_size:      batch_size,
            storage_backend: storage_backend
          )
          raise
        end

        def upload_batch(data:, table:, year:, month:, batch_n:, backend:)
          log.info "Archiver storing batch table=#{table} backend=#{backend || :tmpdir} year=#{year} month=#{month} batch=#{batch_n}"
          case backend
          when :s3
            upload_s3(data: data, table: table, year: year, month: month, batch_n: batch_n)
          when :azure
            upload_azure(data: data, table: table, year: year, month: month, batch_n: batch_n)
          else
            upload_tmpdir(data: data, table: table, year: year, month: month, batch_n: batch_n)
          end
        end

        def manifest_stats
          return {} unless postgres?
          return {} unless Legion::Data.connection.table_exists?(:archive_manifest)

          Legion::Data.connection[:archive_manifest]
                      .group_and_count(:source_table)
                      .select_append(
                        Sequel.function(:sum, :row_count).as(:total_rows),
                        Sequel.function(:min, :archived_at).as(:earliest),
                        Sequel.function(:max, :archived_at).as(:latest)
                      )
                      .all
                      .to_h do |row|
            [row[:source_table], {
              batches:    row[:count],
              total_rows: row[:total_rows].to_i,
              earliest:   row[:earliest],
              latest:     row[:latest]
            }]
          end
        end

        private

        def postgres?
          Legion::Data::Connection.adapter == :postgres
        end

        def serialize_rows(rows)
          rows.map { |row| json_dump(row) }.join("\n")
        end

        def archive_batches(conn:, table:, cutoff:, batch_size:, storage_backend:)
          now = Time.now.utc
          batches = 0
          total_rows = 0
          paths = []

          while (batch_result = archive_batch(
            conn:            conn,
            table:           table,
            cutoff:          cutoff,
            batch_size:      batch_size,
            batch_n:         batches + 1,
            now:             now,
            storage_backend: storage_backend
          ))
            batches += 1
            total_rows += batch_result[:row_count]
            paths << batch_result[:path]
          end

          { batches: batches, total_rows: total_rows, paths: paths }
        end

        def archive_batch(conn:, table:, cutoff:, batch_size:, batch_n:, now:, storage_backend:)
          rows = conn[table].where { created_at < cutoff }.limit(batch_size).all
          return if rows.empty?

          compressed = gzip_compress(serialize_rows(rows))
          path = upload_batch(
            data:    compressed,
            table:   table.to_s,
            year:    now.year,
            month:   now.month,
            batch_n: batch_n,
            backend: storage_backend
          )

          record_archived_batch(
            conn:       conn,
            table:      table,
            rows:       rows,
            compressed: compressed,
            path:       path,
            now:        now
          )

          { row_count: rows.size, path: path }
        end

        def record_archived_batch(conn:, table:, rows:, compressed:, path:, now:)
          conn.transaction do
            conn[:archive_manifest].insert(
              batch_id:     SecureRandom.uuid,
              source_table: table.to_s,
              row_count:    rows.size,
              checksum:     Digest::SHA256.hexdigest(compressed),
              storage_path: path,
              archived_at:  now
            )
            conn[table].where(id: rows.map { |row| row[:id] }).delete
          end
        end

        def json_dump(obj)
          Legion::JSON.generate(obj)
        end

        def gzip_compress(data)
          output = StringIO.new
          output.binmode
          gz = Zlib::GzipWriter.new(output)
          gz.write(data)
          gz.close
          output.string
        end

        def upload_s3(data:, table:, year:, month:, batch_n:)
          raise UploadError, 'S3 backend not available: Legion::Extensions::S3::Runners::Put not defined' unless defined?(Legion::Extensions::S3::Runners::Put)

          key = "legion-archive/#{table}/#{year}/#{month}/batch_#{batch_n}.jsonl.gz"
          Legion::Extensions::S3::Runners::Put.run(key: key, body: data)
          log.info "Archiver uploaded batch to s3 key=#{key}"
          "s3://#{key}"
        rescue UploadError => e
          handle_exception(e, level: :error, handled: false, operation: :upload_s3, table: table, year: year, month: month, batch_n: batch_n)
          raise
        rescue StandardError => e
          handle_exception(e, level: :error, handled: true, operation: :upload_s3, table: table, year: year, month: month, batch_n: batch_n)
          raise UploadError, "S3 upload failed: #{e.message}"
        end

        def upload_azure(data:, table:, year:, month:, batch_n:)
          unless defined?(Legion::Extensions::AzureStorage::Runners::Upload)
            raise UploadError, 'Azure backend not available: Legion::Extensions::AzureStorage::Runners::Upload not defined'
          end

          blob_name = "legion-archive/#{table}/#{year}/#{month}/batch_#{batch_n}.jsonl.gz"
          Legion::Extensions::AzureStorage::Runners::Upload.run(blob_name: blob_name, data: data)
          log.info "Archiver uploaded batch to azure blob=#{blob_name}"
          "azure://#{blob_name}"
        rescue UploadError => e
          handle_exception(e, level: :error, handled: false, operation: :upload_azure, table: table, year: year, month: month, batch_n: batch_n)
          raise
        rescue StandardError => e
          handle_exception(e, level: :error, handled: false, operation: :upload_azure, table: table, year: year, month: month, batch_n: batch_n)
          raise UploadError, "Azure upload failed: #{e.message}"
        end

        def upload_tmpdir(data:, table:, year:, month:, batch_n:)
          dir = File.join(Dir.tmpdir, 'legion-archive', table.to_s, year.to_s, month.to_s)
          FileUtils.mkdir_p(dir)
          path = File.join(dir, "batch_#{batch_n}.jsonl.gz")
          File.binwrite(path, data)
          log.info "Archiver stored batch locally path=#{path}"
          "file://#{path}"
        rescue StandardError => e
          handle_exception(e, level: :error, handled: true, operation: :upload_tmpdir, table: table, year: year, month: month, batch_n: batch_n)
          raise UploadError, "Tmpdir upload failed: #{e.message}"
        end
      end
    end
  end
end
