# frozen_string_literal: true

require 'digest'
require 'legion/json'
require 'time'

module Legion
  module Data
    module AuditLogHashChain
      GENESIS_HASH = ('0' * 64).freeze
      CANONICAL_FIELDS = %i[
        principal_id action resource source status detail created_at previous_hash
      ].freeze

      class << self
        def compute_hash(record)
          Digest::SHA256.hexdigest(canonical_payload(record))
        end

        def verify(records)
          previous_hash = GENESIS_HASH
          length = 0
          records.each do |record|
            return invalid(record, :parent_mismatch) unless value_for(record, :previous_hash).to_s == previous_hash

            expected = compute_hash(record)
            return invalid(record, :hash_mismatch) unless value_for(record, :record_hash).to_s == expected

            previous_hash = expected
            length += 1
          end

          { valid: true, length: length }
        end

        def canonical_payload(record)
          CANONICAL_FIELDS.map do |field|
            "#{field}:#{canonical_value(value_for(record, field))}"
          end.join('|')
        end

        private

        def invalid(record, reason)
          { valid: false, broken_at: value_for(record, :id), reason: reason }
        end

        def canonical_value(value)
          case value
          when Time
            value.utc.iso8601(6)
          when DateTime
            value.to_time.utc.iso8601(6)
          when Hash
            Legion::JSON.dump(canonical_hash(value))
          when Array
            Legion::JSON.dump(value.map { |item| canonical_json_value(item) })
          else
            value.to_s
          end
        end

        def canonical_json_value(value)
          case value
          when Hash then canonical_hash(value)
          when Array then value.map { |item| canonical_json_value(item) }
          else value
          end
        end

        def canonical_hash(hash)
          hash.keys.map(&:to_s).sort.to_h do |key|
            [key, canonical_json_value(hash.fetch(key) { hash.fetch(key.to_sym) })]
          end
        end

        def value_for(record, field)
          return record[field] if record.respond_to?(:[]) && !record[field].nil?
          return record[field.to_s] if record.respond_to?(:[]) && !record[field.to_s].nil?
          return record.public_send(field) if record.respond_to?(field)

          nil
        end
      end
    end
  end
end
