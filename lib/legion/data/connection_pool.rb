# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module Data
    module ConnectionPool
      include Legion::Logging::Helper

      def self.extended(pool)
        pool.instance_variable_set(:@shutdown_mutex, Mutex.new)
        pool.instance_variable_set(:@shutdown_condition, ConditionVariable.new)
        pool.instance_variable_set(:@shutdown_owners, {}.compare_by_identity)
        pool.instance_variable_set(:@shutdown_state, :open)
      end

      def hold(server = :default)
        owner = Sequel.current
        @shutdown_mutex.synchronize do
          raise Sequel::Error, 'Database pool is shutting down or closed' unless @shutdown_state == :open || @shutdown_owners.key?(owner)

          @shutdown_owners[owner] = @shutdown_owners.fetch(owner, 0) + 1
        end
        begin
          super
        ensure
          finish = @shutdown_mutex.synchronize do
            @shutdown_owners[owner] -= 1
            @shutdown_owners.delete(owner) if @shutdown_owners[owner].zero?
            if @shutdown_state == :draining && @shutdown_owners.empty?
              @shutdown_state = :closing
              true
            end
          end
          finish_shutdown if finish
        end
      end

      def shutdown(timeout:, &on_closed)
        deadline = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) + timeout
        finish = @shutdown_mutex.synchronize do
          @shutdown_callback ||= on_closed
          @shutdown_state = :draining if %i[open failed].include?(@shutdown_state)
          if @shutdown_state == :draining && @shutdown_owners.empty?
            @shutdown_state = :closing
            true
          end
        end
        finish_shutdown if finish
        @shutdown_mutex.synchronize do
          until @shutdown_state == :closed
            remaining = deadline - ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
            return false if remaining <= 0 || @shutdown_state == :failed || @shutdown_owners.key?(Sequel.current)

            @shutdown_condition.wait(@shutdown_mutex, remaining)
          end
        end
        true
      end

      def shutdown_status
        @shutdown_mutex.synchronize { { state: @shutdown_state, active_requests: @shutdown_owners.size } }
      end

      private

      def finish_shutdown
        disconnect
        @shutdown_callback.call
        @shutdown_mutex.synchronize do
          @shutdown_state = :closed
          @shutdown_condition.broadcast
        end
      rescue StandardError => e
        @shutdown_mutex.synchronize do
          @shutdown_state = :failed
          @shutdown_condition.broadcast
        end
        handle_exception(e, level: :error, handled: true, operation: :pool_shutdown)
      end
    end
  end
end
