# frozen_string_literal: true

require 'spec_helper'
require 'legion/data/event_store'

RSpec.describe Legion::Data::EventStore do
  let(:db) do
    Sequel.sqlite.tap do |database|
      Sequel::Migrator.run(database, File.expand_path('../../../lib/legion/data/migrations', __dir__))
    end
  end

  after do
    db.disconnect if defined?(db) && db
  end

  describe 'GOVERNANCE_EVENT_TYPES' do
    it 'includes consent and extinction events' do
      expect(described_class::GOVERNANCE_EVENT_TYPES).to include('consent.granted', 'extinction.triggered')
    end
  end

  describe '.append' do
    it 'returns error when db unavailable' do
      allow(described_class).to receive(:db_ready?).and_return(false)
      result = described_class.append(stream: 'test', type: 'consent.granted')
      expect(result[:error]).to include('db unavailable')
    end
  end

  describe '.read_stream' do
    it 'returns empty array when db unavailable' do
      allow(described_class).to receive(:db_ready?).and_return(false)
      expect(described_class.read_stream('test')).to eq([])
    end
  end

  describe '.verify_chain' do
    it 'returns invalid when db unavailable' do
      allow(described_class).to receive(:db_ready?).and_return(false)
      result = described_class.verify_chain('test')
      expect(result[:valid]).to be false
    end
  end

  context 'with a live database' do
    before do
      allow(Legion::Data).to receive(:connection).and_return(db)
      allow(described_class).to receive(:db_ready?).and_return(true)
    end

    it 'round-trips data and metadata through append and read_stream' do
      described_class.append(
        stream:   'stream-1',
        type:     'consent.granted',
        data:     { granted: true },
        metadata: { request_id: 'req-1', actor: 'worker-1' }
      )

      events = described_class.read_stream('stream-1')

      expect(events.size).to eq(1)
      expect(events.first[:data]).to eq({ granted: true })
      expect(events.first[:metadata]).to eq({ request_id: 'req-1', actor: 'worker-1' })
    end

    it 'verifies a multi-event chain when metadata is unchanged' do
      described_class.append(
        stream:   'stream-2',
        type:     'consent.granted',
        data:     { step: 1 },
        metadata: { request_id: 'req-1' }
      )
      described_class.append(
        stream:   'stream-2',
        type:     'consent.modified',
        data:     { step: 2 },
        metadata: { request_id: 'req-2' }
      )

      result = described_class.verify_chain('stream-2')

      expect(result).to eq(valid: true, length: 2)
    end

    it 'propagates unrelated insert errors and releases the stream claim on rollback' do
      expect { described_class.append(stream: 'rollback', type: nil) }.to raise_error(Sequel::NotNullConstraintViolation)

      event = described_class.append(stream: 'rollback', type: 'consent.granted')
      expect(event[:sequence]).to eq(1)
      expect(described_class.verify_chain('rollback')).to eq(valid: true, length: 1)
    end

    it 'detects metadata tampering for newly-written rows' do
      described_class.append(
        stream:   'stream-3',
        type:     'consent.granted',
        data:     { granted: true },
        metadata: { request_id: 'req-1' }
      )

      db[:governance_events]
        .where(stream_id: 'stream-3', sequence_number: 1)
        .update(metadata_json: Legion::JSON.dump(request_id: 'tampered'))

      result = described_class.verify_chain('stream-3')

      expect(result).to eq(valid: false, broken_at: 1)
    end

    it 'continues to verify legacy rows hashed without metadata_json' do
      stream = 'legacy-stream'
      type = 'consent.granted'
      data_json = Legion::JSON.dump(granted: true)
      metadata_json = Legion::JSON.dump(request_id: 'req-1')
      previous_hash = '0' * 64
      legacy_hash = Digest::SHA256.hexdigest("#{stream}:1:#{type}:#{data_json}:#{previous_hash}")

      db[:governance_events].insert(
        stream_id:       stream,
        event_type:      type,
        sequence_number: 1,
        data_json:       data_json,
        metadata_json:   metadata_json,
        event_hash:      legacy_hash,
        previous_hash:   previous_hash,
        created_at:      Time.now
      )

      result = described_class.verify_chain(stream)

      expect(result).to eq(valid: true, length: 1, legacy_hashes: 1)
    end
  end
end
