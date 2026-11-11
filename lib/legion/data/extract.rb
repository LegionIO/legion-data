# frozen_string_literal: true

require 'legion/logging/helper'
require 'securerandom'
require_relative 'extract/type_detector'
require_relative 'extract/handlers/base'

module Legion
  module Data
    module Extract
      class << self
        include Legion::Logging::Helper

        def extract(source, type: :auto)
          extract_id = SecureRandom.uuid
          timings = []
          detected_type = timed_step(:detect_type, timings) do
            type == :auto ? TypeDetector.detect(source) : type&.to_sym
          end
          unless detected_type
            result = { success: false, text: nil, error: :unknown_type, extract_id: extract_id,
                       step_timings: timings }
            persist_step_timings(extract_id, timings)
            return result
          end

          handler = timed_step(:resolve_handler, timings) { Handlers::Base.for_type(detected_type) }
          unless handler
            result = { success: false, text: nil, error: :no_handler, type: detected_type, extract_id: extract_id,
                       step_timings: timings }
            persist_step_timings(extract_id, timings)
            return result
          end

          available = timed_step(:check_availability, timings) { handler.available? }
          unless available
            return { success: false, text: nil, error: :gem_not_installed,
                     gem: handler.gem_name, type: detected_type, extract_id: extract_id,
                     step_timings: timings }.tap { persist_step_timings(extract_id, timings) }
          end

          log.info "Extract starting type=#{detected_type} handler=#{handler.name}"
          result = timed_step(:handler_extract, timings) { handler.extract(source) }
          if result[:text]
            log.info "Extract succeeded type=#{detected_type}"
            { success: true, text: result[:text], metadata: result[:metadata], type: detected_type,
              extract_id: extract_id, step_timings: timings }
          else
            log.warn "Extract failed type=#{detected_type} error=#{result[:error]}"
            { success: false, text: nil, error: result[:error], type: detected_type,
              extract_id: extract_id, step_timings: timings }
          end.tap { persist_step_timings(extract_id, timings) }
        rescue StandardError => e
          handle_exception(e, level: :error, handled: true, operation: :extract, type: detected_type)
          persist_step_timings(extract_id, timings) if extract_id
          { success: false, text: nil, error: e.message, type: detected_type, extract_id: extract_id,
            step_timings: timings }
        end

        def supported_types
          load_all_handlers
          Handlers::Base.supported_types
        end

        def can_extract?(type)
          load_all_handlers
          handler = Handlers::Base.for_type(type&.to_sym)
          handler&.available? || false
        end

        def register_handler(type, klass)
          Handlers::Base.instance_variable_set(:@registry,
                                               Handlers::Base.registry.merge(type.to_sym => klass).freeze)
        end

        private

        def timed_step(name, timings)
          monotonic_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          start_time = Time.now.utc
          result = yield
          record_step_timing(timings, name: name, start_time: start_time, monotonic_start: monotonic_start,
                                      status: :success)
          result
        rescue StandardError => e
          record_step_timing(timings, name: name, start_time: start_time, monotonic_start: monotonic_start,
                                      status: :error, error: "#{e.class}: #{e.message}")
          raise
        end

        def record_step_timing(timings, name:, start_time:, monotonic_start:, status:, error: nil)
          end_time = Time.now.utc
          duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - monotonic_start) * 1000).round
          timings << {
            name:        name.to_s,
            start_time:  start_time,
            end_time:    end_time,
            status:      status.to_s,
            error:       error,
            duration_ms: duration_ms
          }
        end

        def persist_step_timings(extract_id, timings)
          return unless Legion::Data.connected?

          existing_steps = Legion::Data::Model::ExtractStepTiming.where(extract_id: extract_id).select_map(:name)
          timings.each do |timing|
            next if existing_steps.include?(timing[:name])

            Legion::Data::Model::ExtractStepTiming.create(timing.merge(extract_id: extract_id))
          end
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: true, operation: :persist_extract_step_timings,
                            extract_id: extract_id)
        end

        def load_all_handlers
          return if @handlers_loaded

          Dir[File.join(__dir__, 'extract', 'handlers', '*.rb')].each do |f|
            require f unless f.end_with?('base.rb')
          end
          @handlers_loaded = true
        end
      end
    end
  end
end
