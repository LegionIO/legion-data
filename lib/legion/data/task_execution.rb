# frozen_string_literal: true

require 'securerandom'
require 'time'
require 'sequel'
require 'legion/json'
require 'legion/logging/helper'
require 'legion/settings/task_execution'

module Legion
  module Data
    module TaskExecution
      extend Legion::Logging::Helper
      extend Legion::Settings::TaskExecution::Helper

      JSON_COLUMNS = %i[function_args payload results transformation_result].freeze
      OWNERSHIP_COLUMNS = %i[id execution_key execution_token execution_owner execution_lease_until attempt_count lock_version completed_at retry_at].freeze

      class << self
        def create_task(values:, idempotency_key:, dispatch: nil)
          raise ArgumentError, 'idempotency_key must not be empty' if idempotency_key.to_s.empty?
          raise ArgumentError, 'task ownership is managed by TaskExecution' if values.keys.intersect?(OWNERSHIP_COLUMNS)

          db = Legion::Data.connection
          task_execution_transaction(db: db) do
            attributes = task_execution_encode(values: values)
            attributes[:created] ||= Time.now
            attributes[:status] ||= task_status(name: :queued)
            task_execution_validate_status(status: attributes[:status])
            attributes[:completed_at] = Time.now if task_terminal_status?(status: attributes[:status])
            attributes[:cancelled_at] ||= Time.now if attributes[:status] == task_status(name: :cancelled)
            attributes[:execution_key] = idempotency_key
            attributes[:idempotency_expires_at] ||= Time.now + task_execution_settings.fetch(:execution).fetch(:idempotency_ttl_seconds)
            inserted = task_execution_insert_unique(db: db, table: :tasks, values: attributes, key: { execution_key: idempotency_key })
            task = inserted.fetch(:row)
            enqueue_dispatch(**dispatch, task_id: task.fetch(:id)) if inserted[:created] && dispatch
            { created: inserted.fetch(:created), task: task }
          end
        end

        def claim_task(task_id:, owner:, now: Time.now)
          raise ArgumentError, 'owner must not be empty' if owner.to_s.empty?

          now = now.getlocal
          db = Legion::Data.connection
          task_execution_transaction(db: db) do
            task = task_execution_lock(db: db, task_id: task_id)
            reason = task_execution_guard(db: db, task: task, now: now)
            reason ||= :terminal if task_terminal_status?(status: task[:status])
            reason ||= :leased if task[:execution_token] && task[:execution_lease_until]
            reason ||= :not_due if task[:retry_at] && task[:retry_at] > now
            reason ||= :not_due if task[:status] == task_status(name: :delayed)
            next { claimed: false, task: task, token: nil, attempt_id: nil, reason: reason } if reason

            token = SecureRandom.uuid
            lease_until = now + task_execution_settings.fetch(:execution).fetch(:lease_seconds)
            number = task.fetch(:attempt_count) + 1
            changed = task_execution_update(db: db, task: task, values: {
                                              status: task_status(name: :running), execution_token: token, execution_owner: owner,
                                              execution_lease_until: lease_until, attempt_count: number, retry_at: nil, completed_at: nil
                                            })
            next { claimed: false, task: task, token: nil, attempt_id: nil, reason: :conflict } unless changed

            attempt_id = db[:task_attempts].insert(uuid: SecureRandom.uuid, task_id: task_id, number: number, token: token, owner: owner,
                                                   status: task_status(name: :running), lease_until: lease_until, created_at: now)
            { claimed: true, task: task, token: token, attempt_id: attempt_id, reason: nil }
          end
        end

        def renew_task_lease(task_id:, token:, now: Time.now)
          now = now.getlocal
          db = Legion::Data.connection
          task_execution_transaction(db: db) do
            task = task_execution_lock(db: db, task_id: task_id)
            reason = task_execution_guard(db: db, task: task, now: now)
            if reason || task[:status] != task_status(name: :running) || token.to_s.empty? || task[:execution_token] != token
              next { renewed: false, task: task }
            end

            lease_until = now + task_execution_settings.fetch(:execution).fetch(:lease_seconds)
            changed = task_execution_update(db: db, task: task, values: { execution_lease_until: lease_until })
            if changed
              count = db[:task_attempts].where(task_id: task_id, token: token, finished_at: nil).update(lease_until: lease_until, updated_at: now)
              raise Sequel::Error, 'Active task attempt is missing' unless count == 1
            end
            { renewed: changed, task: task }
          end
        end

        def transition_task(task_id:, status:, expected_status: nil, token: nil, values: {})
          task_execution_validate_status(status: status)
          raise ArgumentError, 'task ownership is managed by TaskExecution' if values.keys.intersect?(OWNERSHIP_COLUMNS + [:status])

          db = Legion::Data.connection
          task_execution_transaction(db: db) do
            task = task_execution_lock(db: db, task_id: task_id)
            reason = task_execution_transition_reason(db: db, task: task, status: status, expected_status: expected_status, token: token)
            next { changed: false, task: task, reason: reason } if reason

            attributes = task_execution_encode(values: values).merge(status: status)
            if status == task_status(name: :retry_pending)
              attributes.merge!(task_execution_retry_values(task: task))
            elsif task_terminal_status?(status: status)
              attributes[:completed_at] = Time.now
              attributes[:execution_lease_until] = nil
              attributes[:cancelled_at] ||= Time.now if status == task_status(name: :cancelled)
            end
            changed = task_execution_update(db: db, task: task, values: attributes)
            task_execution_finish_attempt(db: db, task: task, status: status, results: task[:results]) if changed && task_terminal_status?(status: status)
            { changed: changed, task: task, reason: changed ? nil : :conflict }
          end
        end

        def complete_task(task_id:, status:, result:, token: nil, continuation: nil)
          task_execution_validate_status(status: status)
          retrying = status == task_status(name: :retry_pending)
          raise ArgumentError, 'completion must be terminal or retry_pending' unless retrying || task_terminal_status?(status: status)
          raise ArgumentError, 'only successful completion can dispatch a continuation' if continuation && status != task_status(name: :completed)

          db = Legion::Data.connection
          task_execution_transaction(db: db) do
            task = task_execution_lock(db: db, task_id: task_id)
            reason = task_execution_guard(db: db, task: task, now: Time.now)
            reason ||= :terminal if task_terminal_status?(status: task[:status])
            reason ||= :owner_mismatch if task[:execution_token] != token
            next { changed: false, task: task } if reason

            attributes, attempt_status = task_execution_completion_values(task: task, status: status, result: result, token: token)
            attempt_task = task.dup
            changed = task_execution_update(db: db, task: task, values: attributes)
            if changed
              task_execution_finish_attempt(db: db, task: attempt_task, status: attempt_status, results: attributes[:results])
              enqueue_dispatch(**continuation, task_id: task_id) if continuation
            end
            { changed: changed, task: task }
          end
        end

        def enqueue_dispatch(event_key:, message_type:, options:, task_id: nil)
          raise ArgumentError, 'event_key must not be empty' if event_key.to_s.empty?
          raise ArgumentError, 'message_type must not be empty' if message_type.to_s.empty?
          raise ArgumentError, 'dispatch options must be a Hash' unless options.is_a?(Hash)

          db = Legion::Data.connection
          task_execution_transaction(db: db) do
            envelope = task_id ? options.merge(task_id: task_id) : options
            inserted = task_execution_insert_unique(db: db, table: :task_dispatches, key: { event_key: event_key }, values: {
                                                      uuid: SecureRandom.uuid, event_key: event_key, message_type: message_type,
                                                     options: Legion::JSON.dump(envelope), task_id: task_id,
                                                     status: task_execution_settings.fetch(:outbox).fetch(:statuses).fetch(:pending)
                                                    })
            row = inserted.fetch(:row)
            raise ArgumentError, 'event_key already belongs to another dispatch identity' if row[:task_id] != task_id || row[:message_type] != message_type

            { created: inserted.fetch(:created), dispatch: task_execution_decode_dispatch(row: inserted.fetch(:row)) }
          end
        end

        def enqueue_task_dispatch(task_id:, event_key:, message_type:, options:, expected_status:)
          db = Legion::Data.connection
          task_execution_transaction(db: db) do
            task = task_execution_lock(db: db, task_id: task_id)
            reason = task_execution_guard(db: db, task: task, now: Time.now)
            if reason || task_terminal_status?(status: task[:status]) || task[:status] != expected_status || task[:execution_token]
              row = db[:task_dispatches].where(event_key: event_key, task_id: task_id).first
              next { created: false, dispatch: row && task_execution_decode_dispatch(row: row) }
            end
            changed = task_execution_update(db: db, task: task, values: { status: task_status(name: :dispatching) })
            next { created: false, dispatch: nil } unless changed

            enqueue_dispatch(event_key: event_key, message_type: message_type, options: options, task_id: task_id)
          end
        end

        def claim_dispatches(owner:, limit: nil, now: Time.now)
          raise ArgumentError, 'owner must not be empty' if owner.to_s.empty?

          limit ||= task_execution_settings.fetch(:outbox).fetch(:batch_size)
          raise ArgumentError, 'limit must be a positive Integer' unless limit.is_a?(Integer) && limit.positive?

          now = now.getlocal
          db = Legion::Data.connection
          task_execution_transaction(db: db) do
            available = db[:task_dispatches].where(delivered_at: nil, discarded_at: nil)
                                            .where(Sequel.|({ token: nil }, Sequel[:lease_until] <= now))
            candidates = available.order(:id).limit(limit)
            candidates = candidates.for_update unless db.database_type == :sqlite
            candidates.all.filter_map do |row|
              token = SecureRandom.uuid
              values = { token: token, owner: owner, lease_until: now + task_execution_settings.fetch(:outbox).fetch(:lease_seconds),
                         delivery_attempts: row.fetch(:delivery_attempts) + 1, updated_at: now,
                         status: task_execution_settings.fetch(:outbox).fetch(:statuses).fetch(:claimed) }
              next unless available.where(id: row.fetch(:id)).update(values) == 1

              task_execution_decode_dispatch(row: row.merge(values))
            end
          end
        end

        def ack_dispatch(dispatch_id:, token:)
          return { changed: false } if token.to_s.empty?

          now = Time.now
          changed = Legion::Data.connection[:task_dispatches].where(id: dispatch_id, token: token, delivered_at: nil, discarded_at: nil)
                                .where { lease_until > now }
                                .update(delivered_at: now, token: nil, owner: nil, lease_until: nil, updated_at: now,
                                        status: task_execution_settings.fetch(:outbox).fetch(:statuses).fetch(:delivered))
          { changed: changed == 1 }
        end

        def release_dispatch(dispatch_id:, token:, error:)
          return { changed: false } if token.to_s.empty?

          changed = Legion::Data.connection[:task_dispatches].where(id: dispatch_id, token: token, delivered_at: nil, discarded_at: nil)
                                .update(token: nil, owner: nil, lease_until: nil, last_error: error.to_s, updated_at: Time.now,
                                        status: task_execution_settings.fetch(:outbox).fetch(:statuses).fetch(:pending))
          { changed: changed == 1 }
        end

        def discard_dispatch(dispatch_id:, token:, reason:)
          db = Legion::Data.connection
          task_execution_transaction(db: db) do
            row = db[:task_dispatches].where(id: dispatch_id).first
            next { changed: false, dispatch: row ? task_execution_decode_dispatch(row: row) : {} } if token.to_s.empty?

            now = Time.now
            changed = db[:task_dispatches].where(id: dispatch_id, token: token, delivered_at: nil, discarded_at: nil)
                                          .where { lease_until > now }
                                          .update(discarded_at: now, discard_reason: reason.to_s, token: nil, owner: nil, lease_until: nil, updated_at: now,
                                                  status: task_execution_settings.fetch(:outbox).fetch(:statuses).fetch(:discarded)) == 1
            row = db[:task_dispatches].where(id: dispatch_id).first
            { changed: changed, dispatch: row ? task_execution_decode_dispatch(row: row) : {} }
          end
        end

        private

        def task_execution_transition_reason(db:, task:, status:, expected_status:, token:)
          reason = task_execution_guard(db: db, task: task, now: Time.now)
          return reason if reason
          return :status_mismatch if expected_status && task[:status] != expected_status
          return task_execution_retry_reason(db: db, task: task, token: token) if status == task_status(name: :retry_pending)
          return :terminal if task_terminal_status?(status: task[:status])
          return :claim_required if status == task_status(name: :running)
          return :owner_mismatch if token && token != task[:execution_token]

          control_status = [task_status(name: :cancelled), task_status(name: :expired)].include?(status)
          :owner_mismatch if !control_status && task[:execution_token] && task[:execution_token] != token
        end

        def task_execution_completion_values(task:, status:, result:, token:)
          retrying = status == task_status(name: :retry_pending)
          attempt_status = status
          if retrying
            unless token && result.is_a?(Hash) && result[:success] == false &&
                   [task_status(name: :failed), task_status(name: :exception)].include?(result[:status])
              raise ArgumentError, 'retry_pending requires an owned failed attempt result'
            end

            attempt_status = result.fetch(:status)
            if task[:attempt_count] >= task_execution_settings.fetch(:retry).fetch(:max_attempts)
              status = task_status(name: :failed)
              retrying = false
            end
          end
          attributes = { status: status, results: Legion::JSON.dump(result), execution_lease_until: nil }
          attributes.merge!(retrying ? task_execution_retry_values(task: task) : { completed_at: Time.now })
          attributes[:cancelled_at] = Time.now if status == task_status(name: :cancelled)
          [attributes, attempt_status]
        end

        def task_execution_transaction(db:, &)
          options = db.database_type == :sqlite ? { mode: :immediate } : {}
          db.transaction(**options, &)
        end

        def task_execution_insert_unique(db:, table:, values:, key:)
          id = db.transaction(savepoint: true) { db[table].insert(values) }
          { created: true, row: db[table].where(id: id).first }
        rescue Sequel::UniqueConstraintViolation => e
          log.debug("Task execution duplicate #{table}: #{e.class}")
          existing = db[table].where(key)
          existing = existing.for_update unless db.database_type == :sqlite
          row = existing.first
          raise unless row

          { created: false, row: row }
        end

        def task_execution_lock(db:, task_id:)
          dataset = db[:tasks].where(id: task_id)
          dataset = dataset.for_update unless db.database_type == :sqlite
          dataset.first || raise(Sequel::NoMatchingRow, "Task #{task_id} does not exist")
        end

        def task_execution_update(db:, task:, values:)
          version = task.fetch(:lock_version)
          values = values.merge(lock_version: version + 1, updated: Time.now)
          changed = db[:tasks].where(id: task.fetch(:id), lock_version: version).update(values) == 1
          task.replace(changed ? task.merge(values) : db[:tasks].where(id: task.fetch(:id)).first)
          changed
        end

        def task_execution_guard(db:, task:, now:)
          return if task_terminal_status?(status: task[:status])

          status, reason = if task[:cancelled_at]
                             [task_status(name: :cancelled), :cancelled]
                           elsif task[:deadline_at] && task[:deadline_at] <= now
                             [task_status(name: :expired), :deadline]
                           elsif (task[:execution_lease_until] && task[:execution_lease_until] <= now) ||
                                 (task[:status] == task_status(name: :running) && (!task[:execution_token] || !task[:execution_lease_until]))
                             [task_status(name: :unknown), :unknown]
                           else
                             task_execution_parent_stop(db: db, task: task, now: now)
                           end
          return unless status

          values = { status: status, completed_at: now, execution_lease_until: nil }
          values[:cancelled_at] = task[:cancelled_at] || now if status == task_status(name: :cancelled)
          changed = task_execution_update(db: db, task: task, values: values)
          task_execution_finish_attempt(db: db, task: task, status: status, results: task[:results]) if changed
          changed ? reason : :conflict
        end

        def task_execution_parent_stop(db:, task:, now:)
          return unless task[:parent_id]

          parent = task_execution_lock(db: db, task_id: task[:parent_id])
          if parent[:cancelled_at] || parent[:status] == task_status(name: :cancelled)
            [task_status(name: :cancelled), :cancelled]
          elsif parent[:status] == task_status(name: :expired) || (parent[:deadline_at] && parent[:deadline_at] <= now)
            [task_status(name: :expired), :deadline]
          end
        end

        def task_execution_finish_attempt(db:, task:, status:, results:)
          return unless task[:execution_token]

          db[:task_attempts].where(task_id: task.fetch(:id), token: task[:execution_token], finished_at: nil)
                            .update(status: status, results: results, finished_at: Time.now, updated_at: Time.now)
        end

        def task_execution_retry_reason(db:, task:, token:)
          return :owner_mismatch unless token && token == task[:execution_token]
          return :not_failed unless [task_status(name: :failed), task_status(name: :exception)].include?(task[:status])
          return :attempt_limit if task[:attempt_count] >= task_execution_settings.fetch(:retry).fetch(:max_attempts)
          return :cancelled if task[:cancelled_at]
          return :deadline if task[:deadline_at] && task[:deadline_at] <= Time.now

          attempt = db[:task_attempts].where(task_id: task.fetch(:id), token: token).first
          :not_failed unless attempt && attempt[:finished_at] && [task_status(name: :failed), task_status(name: :exception)].include?(attempt[:status])
        end

        def task_execution_retry_values(task:)
          policy = task_execution_settings.fetch(:retry)
          delay = [policy.fetch(:base_delay_seconds) * (2**(task[:attempt_count] - 1)), policy.fetch(:max_delay_seconds)].min
          { retry_at: Time.now + delay, completed_at: nil, execution_token: nil, execution_owner: nil, execution_lease_until: nil }
        end

        def task_execution_encode(values:)
          values.to_h do |key, value|
            if JSON_COLUMNS.include?(key) && (value.is_a?(Hash) || value.is_a?(Array))
              value = Legion::JSON.dump(value)
            elsif %i[deadline_at cancelled_at].include?(key) && value.is_a?(String)
              value = Time.iso8601(value)
            end
            value = value.getlocal if value.is_a?(Time)
            [key, value]
          end
        end

        def task_execution_decode_dispatch(row:)
          row.merge(options: Legion::JSON.load(row.fetch(:options)))
        end

        def task_execution_validate_status(status:)
          raise ArgumentError, "Unknown task status #{status.inspect}" unless task_execution_settings.fetch(:statuses).value?(status)
        end
      end
    end
  end
end
