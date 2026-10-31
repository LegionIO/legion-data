# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module Data
    module Models
      class << self
        include Legion::Logging::Helper

        attr_reader :loaded_models

        def models
          %w[extension function relationship chain task runner node setting digital_worker
             apollo_entry apollo_relation apollo_expertise apollo_access_log audit_log
             audit_record extract_step_timing
             identity/identity identity/principal identity/providers identity/group
             identity/group_memberships identity/audit_log
             apollo/entries apollo/relation apollo/access_log apollo/expertise
             apollo/operation
             rbac/role_assignments rbac/runner_grants rbac/cross_team_grants
             llm/conversation llm/message llm/message_inference_request
             llm/message_inference_response llm/route_attempt
             llm/message_inference_metric llm/context_accounting_event
             llm/tool_call llm/tool_call_attempt
             llm/conversation_compaction llm/policy_evaluation
             llm/security_event llm/registry_event]
        end

        def load
          log.info 'Loading Legion::Data::Models'
          @loaded_models ||= []
          database = Legion::Data::Connection.sequel
          Sequel::Model.db = database
          require_sequel_models(models)
          bind_database(namespace: Legion::Data::Model, database: database)
          Legion::Settings[:data][:models][:loaded] = true
        end

        def require_sequel_models(files = models)
          # Dir["#{File.dirname(__FILE__)}models/*.rb"].each { |file| puts file }
          files.each { |file| load_sequel_model(file) }
        end

        def load_sequel_model(model)
          log.debug("Trying to load #{model}.rb")
          require_relative "models/#{model}"
          @loaded_models << model
          log.debug("Successfully loaded #{model}")
          model
        rescue LoadError => e
          handle_exception(e, level: :fatal, operation: :load_sequel_model, model: model)
          raise e unless Legion::Settings[:data][:models][:continue_on_load_fail]
        end

        private

        def bind_database(namespace:, database:)
          namespace.constants(false).each do |name|
            value = namespace.const_get(name, false)
            if value.is_a?(Class) && value < Sequel::Model
              next if value.db.equal?(database)

              value.set_dataset(database[value.table_name])
              value.association_reflections.each_value { |reflection| reflection[:cache]&.clear }
            elsif value.is_a?(Module)
              bind_database(namespace: value, database: database)
            end
          end
        end
      end
    end
  end
end
