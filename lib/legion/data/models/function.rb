# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module Data
    module Model
      class Function < Sequel::Model
        include Legion::Logging::Helper

        many_to_one :runner
        one_to_many :trigger_relationships, class: 'Legion::Data::Model::Relationship', key: :trigger_id
        one_to_many :action_relationships, class: 'Legion::Data::Model::Relationship', key: :action_id
        one_to_many :tasks

        def embedding_vector
          return nil unless embedding

          ::JSON.parse(embedding)
        rescue ::JSON::ParserError => e
          handle_exception(e, level: :warn, handled: true, operation: :embedding_vector, id: self[:id])
          nil
        end

        def embedding_vector=(vec)
          self.embedding = vec&.to_json
        end
      end
    end
  end
end
