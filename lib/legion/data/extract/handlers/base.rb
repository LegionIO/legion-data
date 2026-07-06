# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module Data
    module Extract
      module Handlers
        class Base
          @registry = {}.freeze

          class << self
            include Legion::Logging::Helper

            attr_reader :registry

            def inherited(subclass)
              super
              # Deferred registration — subclass defines type after class body loads
              TracePoint.new(:end) do |tp|
                if tp.self == subclass
                  register(subclass) if subclass.respond_to?(:type) && subclass.type
                  tp.disable
                end
              end.enable
            end

            def register(handler_class)
              log.debug "Registered extract handler type=#{handler_class.type} class=#{handler_class.name}"
              @registry = @registry.merge(handler_class.type => handler_class).freeze
            end

            def for_type(type)
              @registry[type&.to_sym]
            end

            def supported_types
              @registry.keys
            end

            # Override in subclasses
            def type = nil
            def extensions = []
            def gem_name = nil

            def extract(_source)
              raise NotImplementedError, "#{name} must implement .extract"
            end

            def available?
              return true if gem_name.nil?

              require gem_name
              true
            rescue LoadError => e
              handle_exception(e, level: :warn, handled: true, operation: :extract_handler_available, handler: name, gem: gem_name)
              false
            end
          end
        end
      end
    end
  end
end
