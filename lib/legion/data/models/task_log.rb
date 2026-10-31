# frozen_string_literal: true

require 'securerandom'

module Legion
  module Data
    module Model
      class TaskLog < Sequel::Model
        many_to_one :task
        many_to_one :node
        many_to_one :function

        def before_create
          self[:uuid] ||= SecureRandom.uuid
          self[:created] ||= Time.now
          self[:created] = self[:created].getlocal if self[:created].is_a?(Time)
          self[:created_at] ||= self[:created]
          self[:created_at] = self[:created_at].getlocal if self[:created_at].is_a?(Time)
          super
        end
      end
    end
  end
end
