# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Data::Model::Task do
  let(:key) { SecureRandom.uuid }

  around do |example|
    described_class.db.transaction(rollback: :always) { example.run }
  end

  it 'canonicalizes nested payload keys without changing array order' do
    left = described_class.idempotency_key_for({ b: [{ d: 4, c: 3 }], a: 1 })
    equivalent = described_class.idempotency_key_for({ 'a' => 1, 'b' => [{ 'c' => 3, 'd' => 4 }] })
    different = described_class.idempotency_key_for({ b: [3, 4], a: 1 })
    expect(left).to eq(equivalent)
    expect(left).not_to eq(different)
  end

  it 'returns the existing model for duplicate positional-hash requests without an implicit TTL' do
    values = { status: 'pending' }.freeze
    first = described_class.create_idempotent(values, idempotency_key: key)
    first.update(status: 'running')
    duplicate = described_class.create_idempotent(values, idempotency_key: key)

    expect(duplicate).to be_a(described_class)
    expect(duplicate.values).to include(id: first.id, status: 'running', idempotency_expires_at: nil)
    expect(described_class.find_active_by_idempotency_key(key, now: Time.now + 86_400).id).to eq(first.id)
    expect(values).to eq(status: 'pending')
  end

  it 'recognizes an active idempotency key stored before durable execution identities existed' do
    existing = described_class.create(status: 'pending', idempotency_key: key)

    expect(described_class.find_active_by_idempotency_key(key).id).to eq(existing.id)
    expect(described_class.create_idempotent({ status: 'pending' }, idempotency_key: key).id).to eq(existing.id)
  end

  it 'allows a new occurrence to reuse a terminal task key' do
    first = described_class.create_idempotent({ status: 'pending' }, idempotency_key: key)
    first.update(status: 'completed')

    expect(described_class.find_active_by_idempotency_key(key)).to be_nil
    next_occurrence = described_class.create_idempotent({ status: 'pending' }, idempotency_key: key)
    expect(next_occurrence.id).not_to eq(first.id)
    expect(described_class[first.id].status).to eq('completed')
    expect(described_class.find_active_by_idempotency_key(key).id).to eq(next_occurrence.id)
  end

  it 'reuses a namespaced completed task key while retaining the next active occurrence' do
    completed = described_class.create_idempotent({ status: 'task.completed' }, idempotency_key: key)
    expect(described_class.find_active_by_idempotency_key(key)).to be_nil

    running = described_class.create_idempotent({ status: 'task.running' }, idempotency_key: key)
    duplicate = described_class.create_idempotent({ status: 'task.queued' }, idempotency_key: key)
    expect(running.id).not_to eq(completed.id)
    expect(duplicate.values).to include(id: running.id, status: 'task.running')
    expect(described_class[completed.id].status).to eq('task.completed')
  end

  it 'allows key reuse at the explicit TTL boundary' do
    now = Time.local(2026, 11, 3, 12)
    allow(Time).to receive(:now).and_return(now)
    first = described_class.create_idempotent({ status: 'pending' }, idempotency_key: key, ttl: 60)
    expect(described_class.find_active_by_idempotency_key(key, now: now + 59).id).to eq(first.id)
    expect(described_class.find_active_by_idempotency_key(key, now: now + 60)).to be_nil

    allow(Time).to receive(:now).and_return(now + 60)
    replacement = described_class.create_idempotent({ status: 'pending' }, idempotency_key: key, ttl: 120)
    expect(replacement.id).not_to eq(first.id)
    expect(replacement.idempotency_expires_at).to eq(now + 180)
  end

  it 'derives a stable key from the explicit payload rather than unrelated model values' do
    first = described_class.create_idempotent({ status: 'pending' }, payload: { b: 2, a: 1 })
    duplicate = described_class.create_idempotent({ status: 'running' }, payload: { 'a' => 1, 'b' => 2 })
    expect(duplicate.id).to eq(first.id)
    expect(duplicate.status).to eq('pending')
  end

  it 'retains task log evidence when a task is removed' do
    task = described_class.create(status: 'completed')
    record = Legion::Data::Model::TaskLog.create(task_id: task.id, entry: 'completed work')
    task.delete

    persisted = Legion::Data::Model::TaskLog[uuid: record[:uuid]]
    expect(persisted.values).to include(task_id: nil, entry: 'completed work')
  end

  it 'allows the same idempotency key after an unrelated foreign-key failure' do
    expect do
      described_class.db.transaction(savepoint: true) do
        described_class.create_idempotent({ status: 'pending', function_id: -1 }, idempotency_key: key)
      end
    end.to raise_error(Sequel::ForeignKeyConstraintViolation)
    task = described_class.create_idempotent({ status: 'pending' }, idempotency_key: key)
    expect(described_class.where(idempotency_key: key).select_map(:id)).to eq([task.id])
  end

  it 'canonicalizes equivalent frozen instants without mutating caller timezone' do
    local = Time.new(2026, 10, 30, 12, 0, 0, '+05:30').freeze
    utc = local.getutc.freeze
    expect(described_class.idempotency_key_for({ at: local })).to eq(described_class.idempotency_key_for({ at: utc }))
    expect(local.utc_offset).to eq(19_800)
  end
end
