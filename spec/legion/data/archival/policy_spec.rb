# frozen_string_literal: true

require 'spec_helper'
require 'legion/data/archival/policy'

RSpec.describe Legion::Data::Archival::Policy do
  describe '.from_settings' do
    around do |example|
      original = Legion::Settings[:data][:archival]
      begin
        example.run
      ensure
        Legion::Settings[:data][:archival] = original
      end
    end

    it 'uses current retention windows after the live configuration is replaced' do
      now = Time.now
      allow(Time).to receive(:now).and_return(now)
      Legion::Settings[:data][:archival] = { warm_after_days: 0, cold_after_days: 30, batch_size: 25, tables: [] }
      policy = described_class.from_settings
      expect(policy.warm_cutoff).to eq(now)
      expect(policy.cold_cutoff).to eq(now - (30 * 86_400))
      expect(policy.tables).to eq([])

      Legion::Settings[:data][:archival] = { warm_after_days: 2, cold_after_days: 40 }
      policy = described_class.from_settings
      expect(policy.warm_cutoff).to eq(now - (2 * 86_400))
      expect(policy.cold_cutoff).to eq(now - (40 * 86_400))
    end

    it 'rejects an invalid configured policy instead of silently choosing defaults' do
      Legion::Settings[:data][:archival] = false
      expect { described_class.from_settings }.to raise_error(NoMethodError)
    end
  end

  describe '#warm_cutoff' do
    it 'returns time warm_after_days ago' do
      policy = described_class.new(warm_after_days: 7)
      expect(policy.warm_cutoff).to be_within(2).of(Time.now - 604_800)
    end
  end

  describe '#cold_cutoff' do
    it 'returns time cold_after_days ago' do
      policy = described_class.new(cold_after_days: 90)
      expect(policy.cold_cutoff).to be_within(2).of(Time.now - (90 * 86_400))
    end
  end
end
