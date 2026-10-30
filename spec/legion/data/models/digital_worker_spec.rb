# frozen_string_literal: true

require 'securerandom'
require 'spec_helper'
Legion::Data::Connection.setup
Legion::Data::Models.load

RSpec.describe Legion::Data::Model::DigitalWorker do
  let(:valid_attrs) do
    {
      worker_id:       SecureRandom.uuid,
      name:            'test-worker',
      entra_app_id:    SecureRandom.uuid,
      owner_msid:      'MS123',
      extension_name:  'lex-test',
      lifecycle_state: 'active',
      consent_tier:    'supervised',
      trust_score:     0.5
    }
  end

  describe 'health_status validation' do
    it 'accepts online as a valid health_status' do
      worker = described_class.new(valid_attrs.merge(health_status: 'online'))
      expect(worker.valid?).to be(true)
    end

    it 'accepts offline as a valid health_status' do
      worker = described_class.new(valid_attrs.merge(health_status: 'offline'))
      expect(worker.valid?).to be(true)
    end

    it 'accepts unknown as a valid health_status' do
      worker = described_class.new(valid_attrs.merge(health_status: 'unknown'))
      expect(worker.valid?).to be(true)
    end

    it 'rejects invalid health_status values' do
      worker = described_class.new(valid_attrs.merge(health_status: 'bad'))
      expect(worker.valid?).to be(false)
      expect(worker.errors[:health_status]).to include('invalid')
    end
  end

  describe '#online?' do
    it 'returns true when health_status is online' do
      worker = described_class.new(valid_attrs.merge(health_status: 'online'))
      expect(worker.online?).to be(true)
    end

    it 'returns false when health_status is offline' do
      worker = described_class.new(valid_attrs.merge(health_status: 'offline'))
      expect(worker.online?).to be(false)
    end
  end

  describe '#offline?' do
    it 'returns true when health_status is offline' do
      worker = described_class.new(valid_attrs.merge(health_status: 'offline'))
      expect(worker.offline?).to be(true)
    end

    it 'returns false when health_status is online' do
      worker = described_class.new(valid_attrs.merge(health_status: 'online'))
      expect(worker.offline?).to be(false)
    end
  end

  describe 'default health_status' do
    it 'defaults health_status to unknown' do
      worker = described_class.create(valid_attrs)
      expect(worker.health_status).to eq('unknown')
      worker.delete
    end
  end
end
