# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Data::Model::Task do
  include Legion::Settings::TaskExecution::Helper

  around do |example|
    original = Legion::Data::Connection.instance_variable_get(:@sequel)
    @execution_key = SecureRandom.uuid
    begin
      Legion::Data::Connection.instance_variable_set(:@sequel, described_class.db)
      example.run
    ensure
      described_class.where(execution_key: @execution_key).delete
      Legion::Data::Connection.instance_variable_set(:@sequel, original)
    end
  end

  it 'canonicalizes nested payload keys without changing array order' do
    left = described_class.idempotency_key_for(payload: { b: [{ d: 4, c: 3 }], a: 1 })
    equivalent = described_class.idempotency_key_for(payload: { 'a' => 1, 'b' => [{ 'c' => 3, 'd' => 4 }] })
    different = described_class.idempotency_key_for(payload: { b: [3, 4], a: 1 })
    expect(left).to eq(equivalent)
    expect(left).not_to eq(different)
  end

  it 'returns one logical task as plain values for duplicate requests' do
    values = { status: task_status(name: :queued), payload: { a: 1 } }
    first = described_class.create_idempotent(values: values, idempotency_key: @execution_key)
    duplicate = described_class.create_idempotent(values: values, idempotency_key: @execution_key)
    expect(duplicate).to be_a(Hash)
    expect(duplicate[:id]).to eq(first[:id])
    expect(described_class.find_active_by_idempotency_key(key: @execution_key)[:id]).to eq(first[:id])
  end

  it 'preserves completed identity and excludes canonical terminal tasks from active lookup' do
    task = described_class.create_idempotent(values: { status: task_status(name: :queued) }, idempotency_key: @execution_key)
    Legion::Data::TaskExecution.complete_task(task_id: task[:id], status: task_status(name: :completed), result: { answer: 42 })
    duplicate = described_class.create_idempotent(values: {}, idempotency_key: @execution_key)
    expect(duplicate[:id]).to eq(task[:id])
    expect(described_class.find_active_by_idempotency_key(key: @execution_key)).to be_nil
    expect(described_class[task[:id]].terminal?).to be(true)
  end

  it 'recognizes configured legacy terminal rows without re-creating their execution identity' do
    task = described_class.create_idempotent(values: {}, idempotency_key: @execution_key)
    legacy = task_execution_settings.fetch(:legacy_terminal_statuses).first
    described_class.where(id: task[:id]).update(status: legacy)
    expect(described_class[task[:id]].terminal?).to be(true)
    expect(described_class.find_active_by_idempotency_key(key: @execution_key)).to be_nil
    expect(described_class.create_idempotent(values: {}, idempotency_key: @execution_key)[:id]).to eq(task[:id])
  end

  it 'persists task log identities and keeps their evidence when a task is removed' do
    task = described_class.create_idempotent(values: {}, idempotency_key: @execution_key)
    occurred_at = Time.utc(2026, 10, 30, 12)
    record = Legion::Data::Model::TaskLog.create(task_id: task[:id], entry: 'completed work', created: occurred_at)
    public_id = record[:uuid]
    expect(public_id).to match(/\A[0-9a-f-]{36}\z/)
    expect(record[:created_at]).to eq(occurred_at)
    described_class.where(id: task[:id]).delete
    persisted = Legion::Data::Model::TaskLog[uuid: public_id]
    expect(persisted.values).to include(task_id: nil, entry: 'completed work')
  ensure
    Legion::Data::Model::TaskLog.where(id: record.id).delete if record
  end
end
