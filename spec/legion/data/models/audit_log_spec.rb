# frozen_string_literal: true

require 'spec_helper'
require 'legion/data/retention'
Legion::Data::Connection.setup
Legion::Data::Models.load

RSpec.describe Legion::Data::Model::AuditLog do
  let(:valid_attrs) do
    {
      event_type:     'runner_execution',
      principal_id:   'worker-123',
      principal_type: 'system',
      action:         'execute',
      resource:       'MyRunner/my_function',
      source:         'amqp',
      node:           'node-01',
      status:         'success',
      duration_ms:    42,
      detail:         '{"task_id":1}',
      record_hash:    'a' * 64,
      previous_hash:  '0' * 64,
      created_at:     Time.now.utc
    }
  end

  it { should be_a Sequel::Model }

  describe 'creation' do
    it 'creates a record with all required fields' do
      record = described_class.create(**valid_attrs)
      expect(record.id).not_to be_nil
      expect(record.event_type).to eq('runner_execution')
      expect(record.record_hash).to eq('a' * 64)
      begin
        record.delete
      rescue StandardError
        nil
      end
      described_class.where(id: record.id).delete
    end
  end

  describe 'validation' do
    it 'accepts runner_execution event_type' do
      record = described_class.new(**valid_attrs)
      expect(record.valid?).to be true
    end

    it 'accepts lifecycle_transition event_type' do
      record = described_class.new(**valid_attrs, event_type: 'lifecycle_transition')
      expect(record.valid?).to be true
    end

    it 'rejects invalid event_type' do
      record = described_class.new(**valid_attrs, event_type: 'bad')
      expect(record.valid?).to be false
      expect(record.errors[:event_type]).to include('invalid')
    end

    %w[success failure denied].each do |status|
      it "accepts #{status} status" do
        record = described_class.new(**valid_attrs, status: status)
        expect(record.valid?).to be true
      end
    end

    it 'rejects invalid status' do
      record = described_class.new(**valid_attrs, status: 'bad')
      expect(record.valid?).to be false
      expect(record.errors[:status]).to include('invalid')
    end
  end

  describe '#parsed_detail' do
    it 'deserializes JSON detail' do
      record = described_class.new(**valid_attrs, detail: '{"key":"value"}')
      expect(record.parsed_detail).to eq({ key: 'value' })
    end

    it 'returns nil when detail is nil' do
      record = described_class.new(**valid_attrs, detail: nil)
      expect(record.parsed_detail).to be_nil
    end

    it 'returns nil when detail is invalid JSON' do
      record = described_class.new(**valid_attrs, detail: 'not-json{{{')
      expect(record.parsed_detail).to be_nil
    end
  end

  describe '.verify_chain' do
    it 'verifies records with the canonical hash chain' do
      first_base = valid_attrs.merge(id: 1, previous_hash: Legion::Data::AuditLogHashChain::GENESIS_HASH)
      first = first_base.merge(record_hash: described_class.compute_hash(first_base))
      second_base = valid_attrs.merge(id: 2, action: 'archive', previous_hash: first[:record_hash])
      second = second_base.merge(record_hash: described_class.compute_hash(second_base))

      expect(described_class.verify_chain([first, second])).to eq({ valid: true, length: 2 })
    end
  end

  describe '.verify_chain across retention boundaries' do
    around do |example|
      @database = Sequel.sqlite
      @database.timezone = :utc
      Sequel::Migrator.run(@database, File.expand_path('../../../../lib/legion/data/migrations', __dir__))
      example.run
    ensure
      @database&.disconnect
    end

    let(:audit_model) { Class.new(described_class).tap { |model| model.set_dataset(@database[:audit_log]) } }

    before do
      allow(Legion::Data).to receive(:connection).and_return(@database)
      previous_hash = Legion::Data::AuditLogHashChain::GENESIS_HASH
      @ids = [120, 90, 60, 0].map do |age|
        attrs = valid_attrs.merge(created_at: Time.now.utc - (age * 86_400), previous_hash: previous_hash)
        attrs[:record_hash] = audit_model.compute_hash(attrs)
        previous_hash = attrs[:record_hash]
        @database[:audit_log].insert(attrs)
      end
    end

    it 'verifies the complete chain after repeated moves, including an entirely archived chain' do
      expect(audit_model.verify_chain).to eq(valid: true, length: 4)
      [100, 70, 40, 0].each do |days|
        result = Legion::Data::Retention.archive_old_records(table: :audit_log, archive_after_days: days)
        expect(result[:archived]).to eq(1)
        expect(audit_model.verify_chain).to eq(valid: true, length: 4)
      end
      expect(@database[:audit_log].count).to eq(0)
      expect(@database[:audit_log_archive].count).to eq(4)
    end

    it 'detects tampering in archived predecessors instead of trusting their stored tail hash' do
      Legion::Data::Retention.archive_old_records(table: :audit_log, archive_after_days: 70)
      @database[:audit_log_archive].where(id: @ids.first).update(action: 'tampered')

      expect(audit_model.verify_chain).to eq(valid: false, broken_at: @ids.first, reason: :hash_mismatch)
    end

    it 'rejects a missing archive prefix rather than accepting the first hot predecessor' do
      Legion::Data::Retention.archive_old_records(table: :audit_log, archive_after_days: 70)
      @database[:audit_log_archive].delete

      expect(audit_model.verify_chain).to eq(valid: false, broken_at: @ids[2], reason: :parent_mismatch)
    end

    it 'does not silently deduplicate a row present in both hot and archive storage' do
      Legion::Data::Retention.archive_old_records(table: :audit_log, archive_after_days: 70)
      duplicate = @database[:audit_log_archive].where(id: @ids.first).first
      duplicate.delete(:archived_at)
      @database[:audit_log].insert(duplicate)

      expect(audit_model.verify_chain).to eq(valid: false, broken_at: @ids.first, reason: :parent_mismatch)
    end
  end

  describe 'immutability' do
    it 'raises on update' do
      record = described_class.create(**valid_attrs)
      expect { record.update(status: 'failure') }.to raise_error(RuntimeError, /immutable.*cannot be updated/)
      described_class.where(id: record.id).delete
    end

    it 'raises on destroy' do
      record = described_class.create(**valid_attrs)
      expect { record.destroy }.to raise_error(RuntimeError, /immutable.*cannot be deleted/)
      described_class.where(id: record.id).delete
    end
  end
end
