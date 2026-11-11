# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Data::Model::TaskLog do
  let(:database) { described_class.db }
  let(:occurred_at) { Time.utc(2026, 10, 30, 12).freeze }
  let(:task_id) { database[:tasks].insert(status: 'task.queued') }
  let(:extension_id) { database[:extensions].insert(name: 'task_log_insert_spec', namespace: 'TaskLogInsertSpec') }
  let(:runner_id) { database[:runners].insert(extension_id: extension_id, name: 'log', namespace: 'TaskLogInsertSpec::Log') }
  let(:function_id) { database[:functions].insert(runner_id: runner_id, name: 'add_log') }

  around do |example|
    database.transaction(rollback: :always) { example.run }
  end

  before do
    allow(Time).to receive(:now).and_return(occurred_at)
  end

  describe '.insert' do
    it 'initializes the positional hash used by Tasker without changing caller data' do
      values = { task_id: task_id, function_id: function_id, entry: '{"message":"tasker log"}' }.freeze
      original = values.dup

      id = described_class.insert(values)

      expect(id).to be_a(Integer)
      record = described_class[id]
      expect(record.values).to include(**original, created: occurred_at, created_at: occurred_at)
      expect(record[:uuid]).to match(/\A[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\z/)
      expect(values).to eq(original)
    end

    it 'initializes the keyword hash used by the Core task helper' do
      id = described_class.insert(task_id: task_id, function_id: function_id, entry: '{"message":"core log"}')

      expect(id).to be_a(Integer)
      record = described_class[id]
      expect(record.values).to include(task_id: task_id, function_id: function_id, entry: '{"message":"core log"}',
                                       created: occurred_at, created_at: occurred_at)
      expect(record[:uuid]).to match(/\A[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\z/)
    end

    it 'preserves a supplied event time and uses it for the canonical event timestamp' do
      event_time = Time.utc(2026, 10, 29, 9).freeze
      values = { task_id: task_id, function_id: function_id, entry: 'delayed log', created: event_time }.freeze

      id = described_class.insert(values)

      expect(described_class[id].values).to include(**values, created_at: event_time)
      expect(values[:created]).to equal(event_time)
      expect(values).not_to have_key(:created_at)
      expect(values).not_to have_key(:uuid)
    end

    it 'respects an explicit UUID and independently supplied event timestamps' do
      uuid = 'b848f19a-faf8-44af-b5ea-f27c24ea7774'
      created = Time.utc(2026, 10, 28, 8).freeze
      created_at = Time.utc(2026, 10, 29, 9).freeze
      values = { uuid: uuid, task_id: task_id, function_id: function_id, entry: 'imported log',
                 created: created, created_at: created_at }.freeze
      original = values.dup

      id = described_class.insert(values)

      expect(described_class[id].values).to include(original)
      expect(values).to eq(original)
      expect(values[:created]).to equal(created)
      expect(values[:created_at]).to equal(created_at)
    end
  end
end
