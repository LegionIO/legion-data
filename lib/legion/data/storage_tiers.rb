# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module Data
    module StorageTiers
      TIERS = { hot: 0, warm: 1, cold: 2 }.freeze

      class << self
        include Legion::Logging::Helper

        def archive_to_warm(table:, age_days: 90, batch_size: 1000)
          db = Legion::Data.connection
          return { archived: 0, reason: 'no_connection' } unless db
          return { archived: 0, reason: 'no_archive_table' } unless db.table_exists?(:data_archive)

          table = table.to_sym
          cutoff = Time.now - (age_days * 86_400)
          archived = db.transaction(savepoint: true, **(db.database_type == :sqlite ? { mode: :immediate } : {})) do
            candidates = db[table].where { created_at < cutoff }.order(:id).limit(batch_size)
            candidates = candidates.for_update unless db.database_type == :sqlite
            records = candidates.all
            next 0 if records.empty?

            records.each do |record|
              db[:data_archive].insert(
                source_table: table.to_s, source_id: record[:id],
                data:         Legion::JSON.dump(record),
                tier:         TIERS[:warm],
                archived_at:  Time.now.utc
              )
            end

            ids = records.map { |r| r[:id] }
            db[table].where(id: ids).delete
          end
          return { archived: 0 } if archived.zero?

          log.info "Archived #{archived} row(s) from #{table} to warm tier"
          { archived: archived, table: table.to_s }
        rescue StandardError => e
          handle_exception(e, level: :error, handled: false, operation: :archive_to_warm, table: table, age_days: age_days, batch_size: batch_size)
          raise
        end

        def export_to_cold(age_days: 365, batch_size: 5000)
          return { exported: 0 } unless Legion::Data.connection&.table_exists?(:data_archive)

          cutoff = Time.now - (age_days * 86_400)
          records = Legion::Data.connection[:data_archive]
                                .where(tier: TIERS[:warm])
                                .where { archived_at < cutoff }
                                .limit(batch_size).all
          return { exported: 0 } if records.empty?

          ids = records.map { |r| r[:id] }
          Legion::Data.connection[:data_archive].where(id: ids).update(tier: TIERS[:cold])
          log.info "Exported #{records.size} row(s) to cold tier"
          { exported: records.size, data: records }
        rescue StandardError => e
          handle_exception(e, level: :error, handled: false, operation: :export_to_cold, age_days: age_days, batch_size: batch_size)
          raise
        end

        def stats
          return {} unless Legion::Data.connection&.table_exists?(:data_archive)

          { warm: count_tier(:warm), cold: count_tier(:cold) }
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: true, operation: :storage_tiers_stats)
          {}
        end

        private

        def count_tier(tier)
          Legion::Data.connection[:data_archive].where(tier: TIERS[tier]).count
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: true, operation: :storage_tiers_count, tier: tier)
          0
        end
      end
    end
  end
end
