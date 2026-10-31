# frozen_string_literal: true

require 'digest'
require 'legion/json'
require 'legion/data/task_execution'
require 'time'

module Legion
  module Data
    module Model
      class Task < Sequel::Model
        extend Legion::Settings::TaskExecution::Helper
        include Legion::Settings::TaskExecution::Helper

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

        def self.idempotency_key_for(payload:)
          Digest::SHA256.hexdigest(Legion::JSON.dump(canonical_payload(payload)))
        end

        def self.find_active_by_idempotency_key(key:, now: Time.now)
          return nil if key.to_s.empty?

          row = where(execution_key: key).first
          return nil unless row
          return nil if task_terminal_status?(status: row[:status])
          return nil if row[:idempotency_expires_at] && row[:idempotency_expires_at] <= now

          row.values
        end

        def self.create_idempotent(values:, payload: nil, idempotency_key: nil, ttl: nil)
          key = idempotency_key || idempotency_key_for(payload: payload || values)
          ttl ||= task_execution_settings.fetch(:execution).fetch(:idempotency_ttl_seconds)
          attributes = values.merge(idempotency_expires_at: Time.now + ttl)
          Legion::Data::TaskExecution.create_task(values: attributes, idempotency_key: key).fetch(:task)
        end

        def cancelled?
          !cancelled_at.nil?
        end

        def terminal?
          task_terminal_status?(status: status)
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
