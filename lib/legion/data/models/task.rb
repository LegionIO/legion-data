# frozen_string_literal: true

require 'digest'
require 'legion/json'
require 'time'

module Legion
  module Data
    module Model
      class Task < Sequel::Model
        TERMINAL_STATUSES = %w[
          completed complete failed error cancelled canceled timeout timed_out
        ].freeze

        many_to_one :function
        many_to_one :relationship
        one_to_many :task_log
        one_to_many :task_logs, class: 'Legion::Data::Model::TaskLog'
        many_to_one :parent, class: self
        one_to_many :children, key: :parent_id, class: self
        many_to_one :master, class: self
        one_to_many :slave, key: :master_id, class: self
        one_to_many :slaves, key: :master_id, class: self
        many_to_one :digital_worker, key: :worker_id, primary_key: :worker_id

        def self.idempotency_key_for(payload)
          Digest::SHA256.hexdigest(Legion::JSON.dump(canonical_payload(payload)))
        end

        def self.find_active_by_idempotency_key(key, now: Time.now)
          return nil if key.to_s.empty?
          return nil unless columns.include?(:idempotency_key)

          where(idempotency_key: key)
            .exclude(status: TERMINAL_STATUSES)
            .where { (idempotency_expires_at =~ nil) | (idempotency_expires_at > now) }
            .reverse_order(:created, :id)
            .first
        end

        def self.create_idempotent(values, payload: nil, idempotency_key: nil, ttl: nil)
          key = idempotency_key || idempotency_key_for(payload || values)
          existing = find_active_by_idempotency_key(key)
          return existing if existing

          expires_at = ttl ? Time.now + ttl : nil
          create(values.merge(idempotency_key: key, idempotency_expires_at: expires_at))
        end

        def cancelled?
          !cancelled_at.nil?
        end

        def self.canonical_payload(value)
          case value
          when Hash
            value.keys.map(&:to_s).sort.to_h do |key|
              [key, canonical_payload(value.fetch(key) { value.fetch(key.to_sym) })]
            end
          when Array
            value.map { |item| canonical_payload(item) }
          when Time
            value.utc.iso8601(6)
          when DateTime
            value.to_time.utc.iso8601(6)
          else
            value
          end
        end
        private_class_method :canonical_payload
      end
    end
  end
end
