# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module Data
    module Model
      class Node < Sequel::Model
        include Legion::Logging::Helper

        one_to_many :task_log
        one_to_many :task_logs, class: 'Legion::Data::Model::TaskLog'
        many_to_one :principal, class: 'Legion::Data::Model::Principal'

        def parsed_metrics
          return nil unless metrics

          Legion::JSON.load(metrics)
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: true, operation: :parsed_metrics, id: self[:id])
          nil
        end

        def parsed_hosted_worker_ids
          return [] unless hosted_worker_ids

          Legion::JSON.load(hosted_worker_ids)
        rescue StandardError => e
          handle_exception(e, level: :warn, handled: true, operation: :parsed_hosted_worker_ids, id: self[:id])
          []
        end
      end
    end
  end
end
