# frozen_string_literal: true

require 'spec_helper'
Legion::Data::Connection.setup
Legion::Data::Models.load

RSpec.describe Legion::Data::Model::Task do
  it { should respond_to? :relationship }
  it { should respond_to? :task_log }
  it { should respond_to? :parent }
  it { should respond_to? :children }
  it { should respond_to? :master }
  it { should respond_to? :slave }
  it { should respond_to? :user_owner }
  it { should respond_to? :group_owner }
  it { should be_a Sequel::Model }

  describe '.idempotency_key_for' do
    it 'returns the same SHA-256 key for hash payloads with different key order' do
      left = described_class.idempotency_key_for({ b: 2, a: 1 })
      right = described_class.idempotency_key_for({ a: 1, b: 2 })

      expect(left).to eq(right)
      expect(left).to match(/\A[0-9a-f]{64}\z/)
    end
  end

  describe '.create_idempotent' do
    it 'returns an existing active task for duplicate payloads' do
      attrs = { status: 'pending', payload: '{"a":1}' }
      first = described_class.create_idempotent(attrs, payload: { a: 1 })
      second = described_class.create_idempotent(attrs, payload: { a: 1 })

      expect(second.id).to eq(first.id)
    end

    it 'creates a new task after the prior idempotency key reaches terminal status' do
      attrs = { status: 'pending', payload: '{"a":2}' }
      first = described_class.create_idempotent(attrs, payload: { a: 2 })
      first.update(status: 'completed')
      second = described_class.create_idempotent(attrs, payload: { a: 2 })

      expect(second.id).not_to eq(first.id)
    end
  end
end
