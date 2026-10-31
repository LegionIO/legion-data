# frozen_string_literal: true

module Legion
  module Data
    module TaskStatus
      STATUSES = {
        queued: 'task.queued', running: 'task.running', completed: 'task.completed',
        exception: 'task.exception', failed: 'task.failed', skipped: 'task.skipped',
        cancelled: 'task.cancelled', expired: 'task.expired', delayed: 'task.delayed',
        dispatching: 'task.dispatching', multiplied: 'task.multiplied', retry_pending: 'task.retry_pending',
        unknown: 'task.unknown', conditioner_queued: 'conditioner.queued', conditioner_failed: 'conditioner.failed',
        conditioner_exception: 'conditioner.exception', transformer_queued: 'transformer.queued',
        transformer_succeeded: 'transformer.succeeded', transformer_validation_failed: 'transformer.validation_failed',
        transformer_failed: 'transformer.failed', blocked: 'task.blocked'
      }.freeze
      TERMINAL_STATUSES = STATUSES.values_at(:completed, :failed, :exception, :skipped, :cancelled, :expired, :multiplied,
                                             :conditioner_failed, :conditioner_exception, :transformer_validation_failed,
                                             :transformer_failed, :unknown, :blocked).freeze
      LEGACY_TERMINAL_STATUSES = %w[completed complete failed error cancelled canceled timeout timed_out exception skipped expired multiplied].freeze

      module Helper
        def task_status(name:)
          raise ArgumentError, 'Task status name must be a String or Symbol' unless name.is_a?(String) || name.is_a?(Symbol)

          STATUSES.fetch(name.to_sym) { raise ArgumentError, "Unknown task status name #{name.inspect}" }
        end

        def task_terminal_status?(status:)
          TERMINAL_STATUSES.include?(status) || LEGACY_TERMINAL_STATUSES.include?(status)
        end
      end
    end
  end
end
