# frozen_string_literal: true

require 'legion/logging/helper'
require 'digest'
require 'legion/data/database_lock'

module Legion
  module Data
    module AuditRecord
      GENESIS_HASH = ('0' * 64).freeze

      class << self
        include Legion::Logging::Helper

        # Append a new record to the named chain. Returns the persisted record hash
        # on success, or an error hash when the database is unavailable.
        #
        # @param chain_id     [String]  chain identifier (scopes the sequence)
        # @param content_type [String]  caller-defined type label
        # @param content_hash [String]  SHA-256 hex digest of the content being recorded
        # @param metadata     [Hash]    optional structured context (serialised to JSON)
        # @param sign         [Boolean] when true, attempt signing via legion-crypt
        def append(chain_id:, content_type:, content_hash:, metadata: {}, sign: false)
          return { error: 'db unavailable' } unless db_ready?

          conn = Legion::Data.connection
          Legion::Data::DatabaseLock.with_claim(database: conn, table: :append_claims,
                                                key: { kind: 'audit', stream_id: chain_id }) do
            parent_hash = latest_chain_hash(conn, chain_id)
            ts          = truncate_to_us(Time.now)
            ch          = compute_chain_hash(parent_hash, content_hash, ts, content_type)
            sig         = sign ? sign_record(ch) : nil
            meta_json   = metadata.empty? ? nil : Legion::JSON.dump(metadata)

            id = conn[:audit_records].insert(
              chain_id:     chain_id,
              content_type: content_type,
              content_hash: content_hash,
              parent_hash:  parent_hash,
              chain_hash:   ch,
              signature:    sig,
              metadata:     meta_json,
              created_at:   ts
            )

            log.debug "AuditRecord append: chain=#{chain_id} type=#{content_type} id=#{id}"
            { id: id, chain_id: chain_id, chain_hash: ch, parent_hash: parent_hash }
          end
        end

        # Walk all records in append order and verify that
        # each record's stored chain_hash matches a freshly computed one.
        #
        # @param chain_id [String]
        # @return [Hash] { valid: Boolean, length: Integer, broken_at: Integer? }
        def verify(chain_id:)
          return { valid: false, error: 'db unavailable' } unless db_ready?

          records = Legion::Data.connection[:audit_records]
                                .where(chain_id: chain_id)
                                .order(:id)
                                .all

          prev_hash = GENESIS_HASH
          records.each do |r|
            unless r[:parent_hash] == prev_hash
              log.warn "AuditRecord chain broken: chain=#{chain_id} id=#{r[:id]}"
              return { valid: false, broken_at: r[:id], reason: :parent_mismatch }
            end

            expected = compute_chain_hash(prev_hash, r[:content_hash], r[:created_at], r[:content_type])
            unless r[:chain_hash] == expected
              log.warn "AuditRecord hash mismatch: chain=#{chain_id} id=#{r[:id]}"
              return { valid: false, broken_at: r[:id], reason: :hash_mismatch }
            end

            prev_hash = r[:chain_hash]
          end

          { valid: true, length: records.size }
        end

        # Return all records for a chain as deserialised hashes.
        #
        # @param chain_id [String]
        # @param since    [Time, nil] optional lower bound on created_at
        # @param limit    [Integer]
        def walk(chain_id:, since: nil, limit: 1000)
          return [] unless db_ready?

          ds = Legion::Data.connection[:audit_records].where(chain_id: chain_id)
          ds = ds.where { created_at >= since } if since
          ds.order(:id).limit(limit).all.map { |r| deserialize(r) }
        end

        # Return records filtered by content_type across all chains.
        #
        # @param content_type [String]
        # @param since        [Time, nil]
        # @param limit        [Integer]
        def query_by_type(content_type:, since: nil, limit: 100)
          return [] unless db_ready?

          ds = Legion::Data.connection[:audit_records].where(content_type: content_type)
          ds = ds.where { created_at >= since } if since
          ds.order(Sequel.desc(:created_at)).limit(limit).all.map { |r| deserialize(r) }
        end

        # SHA-256 of "parent_hash:content_hash:unix_ts_us:content_type".
        #
        # The timestamp is normalised to microseconds-since-epoch. PostgreSQL
        # TIMESTAMP columns have microsecond precision, so nanosecond values
        # written by Ruby would be truncated on read, causing recomputed hashes
        # to diverge. Microsecond normalisation keeps write-time and read-time
        # hashes identical across all supported adapters.
        def compute_chain_hash(parent_hash, content_hash, timestamp, content_type)
          ts_us = normalise_timestamp_us(timestamp)
          Digest::SHA256.hexdigest("#{parent_hash}:#{content_hash}:#{ts_us}:#{content_type}")
        end

        private

        # Normalise a timestamp to integer microseconds-since-epoch regardless of
        # whether the database returned a Time, DateTime, or String. Always uses
        # the absolute epoch value so timezone differences don't affect the hash.
        def normalise_timestamp_us(timestamp)
          t = case timestamp
              when ::Time     then timestamp
              when ::DateTime then timestamp.to_time
              else ::Time.parse(timestamp.to_s)
              end
          (t.to_r * 1_000_000).to_i
        end

        def truncate_to_us(time)
          us = (time.to_r * 1_000_000).to_i
          ::Time.at(Rational(us, 1_000_000))
        end

        def latest_chain_hash(conn, chain_id)
          records = conn[:audit_records]
                    .select(:chain_hash)
                    .where(chain_id: chain_id)
                    .order(Sequel.desc(:id))
          records = records.for_update unless conn.database_type == :sqlite
          last = records.first
          last ? last[:chain_hash] : GENESIS_HASH
        end

        def sign_record(chain_hash)
          return nil unless defined?(Legion::Crypt) && Legion::Crypt.respond_to?(:sign)

          Legion::Crypt.sign(chain_hash)
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: true, operation: :sign_record)
          nil
        end

        def deserialize(row)
          {
            id:           row[:id],
            chain_id:     row[:chain_id],
            content_type: row[:content_type],
            content_hash: row[:content_hash],
            parent_hash:  row[:parent_hash],
            chain_hash:   row[:chain_hash],
            signature:    row[:signature],
            metadata:     row[:metadata] ? Legion::JSON.load(row[:metadata]) : {},
            created_at:   row[:created_at]
          }
        end

        def db_ready?
          defined?(Legion::Data) && Legion::Data.connection&.table_exists?(:audit_records)
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: true, operation: :audit_record_db_ready?)
          false
        end
      end
    end
  end
end
