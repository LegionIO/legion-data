# frozen_string_literal: true

module Legion
  module Data
    module Archival
      class Policy
        DEFAULTS = {
          warm_after_days: 7,
          cold_after_days: 90,
          batch_size:      1000,
          tables:          %w[tasks metering_records].freeze
        }.freeze

        # Per-table date column overrides. The Retention module defaults to :created_at,
        # but legacy tables (like tasks) use :created. Migration 051 may add a created_at
        # column/alias for tasks (implementation varies by adapter); this map forces use of
        # :created so behavior is consistent across legacy schemas and adapters.
        DATE_COLUMN_OVERRIDES = {
          'tasks' => :created
        }.freeze

        attr_reader :warm_after_days, :cold_after_days, :batch_size, :tables

        def initialize(**opts)
          config = DEFAULTS.merge(opts)
          @warm_after_days = config[:warm_after_days]
          @cold_after_days = config[:cold_after_days]
          @batch_size = config[:batch_size]
          @tables = config[:tables]
        end

        def warm_cutoff
          Time.now - (warm_after_days * 86_400)
        end

        def cold_cutoff
          Time.now - (cold_after_days * 86_400)
        end

        def self.from_settings
          new(**Legion::Settings[:data][:archival].slice(:warm_after_days, :cold_after_days, :batch_size, :tables))
        end
      end
    end
  end
end
