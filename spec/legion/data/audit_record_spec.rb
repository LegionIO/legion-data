# frozen_string_literal: true

require 'spec_helper'
require 'legion/data/audit_record'

Legion::Data::Connection.setup unless Legion::Data.connected?
Legion::Data::Migration.migrate(Legion::Data::Connection.sequel,
                                File.expand_path('../../../lib/legion/data/migrations', __dir__))
require 'legion/data/models/audit_record'

RSpec.describe Legion::Data::AuditRecord do
  let(:chain_id)     { "test-chain-#{SecureRandom.hex(4)}" }
  let(:content_type) { 'test.event' }
  let(:content_hash) { Digest::SHA256.hexdigest('hello world') }

  # -------------------------------------------------------------------------
  # GENESIS_HASH constant
  # -------------------------------------------------------------------------
  describe 'GENESIS_HASH' do
    it 'is 64 zero characters' do
      expect(described_class::GENESIS_HASH).to eq('0' * 64)
    end
  end

  # -------------------------------------------------------------------------
  # .compute_chain_hash (via public module_function)
  # -------------------------------------------------------------------------
  describe '.compute_chain_hash' do
    it 'returns a 64-character hex string' do
      ts     = Time.now
      result = described_class.compute_chain_hash('0' * 64, content_hash, ts, content_type)
      expect(result).to match(/\A[0-9a-f]{64}\z/)
    end

    it 'produces different hashes for different parent_hashes' do
      ts = Time.now
      h1 = described_class.compute_chain_hash('a' * 64, content_hash, ts, content_type)
      h2 = described_class.compute_chain_hash('b' * 64, content_hash, ts, content_type)
      expect(h1).not_to eq(h2)
    end

    it 'produces different hashes for different content_hashes' do
      ts = Time.now
      h1 = described_class.compute_chain_hash('0' * 64, 'aaa', ts, content_type)
      h2 = described_class.compute_chain_hash('0' * 64, 'bbb', ts, content_type)
      expect(h1).not_to eq(h2)
    end

    it 'produces different hashes for different content_types' do
      ts = Time.now
      h1 = described_class.compute_chain_hash('0' * 64, content_hash, ts, 'type.a')
      h2 = described_class.compute_chain_hash('0' * 64, content_hash, ts, 'type.b')
      expect(h1).not_to eq(h2)
    end

    it 'is deterministic for the same inputs' do
      ts = Time.utc(2026, 1, 1, 0, 0, 0)
      h1 = described_class.compute_chain_hash('0' * 64, content_hash, ts, content_type)
      h2 = described_class.compute_chain_hash('0' * 64, content_hash, ts, content_type)
      expect(h1).to eq(h2)
    end
  end

  # -------------------------------------------------------------------------
  # DB-unavailable guard
  # -------------------------------------------------------------------------
  describe '.append when db unavailable' do
    before { allow(described_class).to receive(:db_ready?).and_return(false) }

    it 'returns an error hash' do
      result = described_class.append(chain_id: chain_id, content_type: content_type, content_hash: content_hash)
      expect(result[:error]).to include('db unavailable')
    end
  end

  describe '.verify when db unavailable' do
    before { allow(described_class).to receive(:db_ready?).and_return(false) }

    it 'returns valid: false with error' do
      result = described_class.verify(chain_id: chain_id)
      expect(result[:valid]).to be false
      expect(result[:error]).to include('db unavailable')
    end
  end

  describe '.walk when db unavailable' do
    before { allow(described_class).to receive(:db_ready?).and_return(false) }

    it 'returns an empty array' do
      expect(described_class.walk(chain_id: chain_id)).to eq([])
    end
  end

  describe '.query_by_type when db unavailable' do
    before { allow(described_class).to receive(:db_ready?).and_return(false) }

    it 'returns an empty array' do
      expect(described_class.query_by_type(content_type: content_type)).to eq([])
    end
  end

  # -------------------------------------------------------------------------
  # Integration — live SQLite database
  # -------------------------------------------------------------------------
  # Temporarily disables the PG NO UPDATE/NO DELETE rules so tamper specs can
  # directly corrupt rows. On non-PG adapters the rules don't exist and the
  # block just yields directly.
  def with_audit_records_writable(conn)
    if Legion::Data::Connection.adapter == :postgres
      conn.run('ALTER TABLE audit_records DISABLE RULE no_update_audit_records')
      conn.run('ALTER TABLE audit_records DISABLE RULE no_delete_audit_records')
    end
    yield
  ensure
    if Legion::Data::Connection.adapter == :postgres
      conn.run('ALTER TABLE audit_records ENABLE RULE no_update_audit_records')
      conn.run('ALTER TABLE audit_records ENABLE RULE no_delete_audit_records')
    end
  end

  context 'with a live database', :aggregate_failures do
    before do
      Legion::Data::Connection.setup unless Legion::Data.connected?
    end

    describe '.append' do
      it 'inserts a record and returns chain metadata' do
        result = described_class.append(
          chain_id:     chain_id,
          content_type: content_type,
          content_hash: content_hash
        )
        expect(result[:id]).to be_a(Integer)
        expect(result[:chain_id]).to eq(chain_id)
        expect(result[:chain_hash]).to match(/\A[0-9a-f]{64}\z/)
        expect(result[:parent_hash]).to eq(described_class::GENESIS_HASH)
      end

      it 'links the second record to the first via parent_hash' do
        r1 = described_class.append(chain_id: chain_id, content_type: content_type, content_hash: content_hash)
        r2 = described_class.append(
          chain_id:     chain_id,
          content_type: content_type,
          content_hash: Digest::SHA256.hexdigest('record 2')
        )
        expect(r2[:parent_hash]).to eq(r1[:chain_hash])
      end

      it 'stores optional metadata as JSON' do
        described_class.append(
          chain_id:     chain_id,
          content_type: content_type,
          content_hash: content_hash,
          metadata:     { actor: 'system', env: 'test' }
        )
        row = Legion::Data.connection[:audit_records].where(chain_id: chain_id).first
        parsed = Legion::JSON.load(row[:metadata])
        expect(parsed[:actor]).to eq('system')
      end

      it 'uses nil metadata when the hash is empty' do
        described_class.append(chain_id: chain_id, content_type: content_type, content_hash: content_hash)
        row = Legion::Data.connection[:audit_records].where(chain_id: chain_id).first
        expect(row[:metadata]).to be_nil
      end

      it 'keeps chains independent from each other' do
        other_chain = "other-#{SecureRandom.hex(4)}"
        r1 = described_class.append(chain_id: chain_id, content_type: 'a', content_hash: Digest::SHA256.hexdigest('c1'))
        r2 = described_class.append(chain_id: other_chain, content_type: 'a', content_hash: Digest::SHA256.hexdigest('c2'))
        expect(r1[:parent_hash]).to eq(described_class::GENESIS_HASH)
        expect(r2[:parent_hash]).to eq(described_class::GENESIS_HASH)
      end

      it 'propagates invalid inserts without retaining a claim or breaking the next append' do
        expect do
          described_class.append(chain_id: chain_id, content_type: nil, content_hash: content_hash)
        end.to raise_error(Sequel::NotNullConstraintViolation)

        described_class.append(chain_id: chain_id, content_type: content_type, content_hash: content_hash)
        expect(described_class.verify(chain_id: chain_id)).to eq(valid: true, length: 1)
      end
    end

    describe '.verify' do
      it 'returns valid: true, length: 0 for an empty chain' do
        result = described_class.verify(chain_id: "empty-#{SecureRandom.hex(4)}")
        expect(result).to eq({ valid: true, length: 0 })
      end

      it 'returns valid: true for a correctly chained sequence' do
        3.times do |i|
          described_class.append(
            chain_id:     chain_id,
            content_type: content_type,
            content_hash: Digest::SHA256.hexdigest("record #{i}")
          )
        end
        result = described_class.verify(chain_id: chain_id)
        expect(result[:valid]).to be true
        expect(result[:length]).to eq(3)
      end

      it 'detects a tampered chain_hash' do
        described_class.append(chain_id: chain_id, content_type: content_type, content_hash: content_hash)
        described_class.append(chain_id: chain_id, content_type: content_type,
                               content_hash: Digest::SHA256.hexdigest('r2'))

        tampered_hash = Digest::SHA256.hexdigest("tamper-#{chain_id}")
        first = Legion::Data.connection[:audit_records]
                            .where(chain_id: chain_id)
                            .order(:created_at, :id)
                            .first

        # PG NO UPDATE rule silently ignores Sequel updates; bypass via raw SQL.
        with_audit_records_writable(Legion::Data.connection) do
          Legion::Data.connection[:audit_records]
                      .where(id: first[:id])
                      .update(chain_hash: tampered_hash)
        end

        result = described_class.verify(chain_id: chain_id)
        expect(result[:valid]).to be false
        expect(result[:broken_at]).not_to be_nil
      end

      it 'detects a tampered parent_hash' do
        described_class.append(chain_id: chain_id, content_type: content_type, content_hash: content_hash)
        r2 = described_class.append(chain_id: chain_id, content_type: content_type,
                                    content_hash: Digest::SHA256.hexdigest('r2'))

        with_audit_records_writable(Legion::Data.connection) do
          Legion::Data.connection[:audit_records]
                      .where(id: r2[:id])
                      .update(parent_hash: Digest::SHA256.hexdigest("tamper-parent-#{chain_id}"))
        end

        result = described_class.verify(chain_id: chain_id)
        expect(result[:valid]).to be false
        expect(result[:reason]).to eq(:parent_mismatch)
      end
    end

    describe '.walk' do
      it 'preserves append order when writer clocks move backward' do
        timestamp = Time.now
        allow(Time).to receive(:now).and_return(timestamp, timestamp - 60, timestamp - 120)
        hashes = Array.new(3) { |i| Digest::SHA256.hexdigest("walk #{i}") }
        hashes.each do |hash|
          described_class.append(chain_id: chain_id, content_type: content_type, content_hash: hash)
        end

        expect(described_class.walk(chain_id: chain_id).map { |record| record[:content_hash] }).to eq(hashes)
        expect(described_class.verify(chain_id: chain_id)).to eq(valid: true, length: 3)
      end

      it 'accepts a since: filter' do
        described_class.append(chain_id: chain_id, content_type: content_type, content_hash: content_hash)
        described_class.append(chain_id: chain_id, content_type: content_type,
                               content_hash: Digest::SHA256.hexdigest('r2'))

        # A future cutoff should exclude all records already written
        future = Time.now + 3600
        records = described_class.walk(chain_id: chain_id, since: future)
        expect(records).to be_empty
      end

      it 'respects the limit: parameter' do
        5.times do |i|
          described_class.append(
            chain_id:     chain_id,
            content_type: content_type,
            content_hash: Digest::SHA256.hexdigest("lim #{i}")
          )
        end
        records = described_class.walk(chain_id: chain_id, limit: 3)
        expect(records.size).to eq(3)
      end

      it 'returns deserialized hashes with expected keys' do
        described_class.append(
          chain_id:     chain_id,
          content_type: content_type,
          content_hash: content_hash,
          metadata:     { source: 'spec' }
        )
        record = described_class.walk(chain_id: chain_id).first
        expect(record.keys).to include(:id, :chain_id, :content_type, :content_hash,
                                       :parent_hash, :chain_hash, :signature, :metadata, :created_at)
        expect(record[:metadata][:source]).to eq('spec')
      end
    end

    describe '.query_by_type' do
      it 'returns records matching the content_type across chains' do
        ctype = "spec.type.#{SecureRandom.hex(4)}"
        2.times do |i|
          described_class.append(
            chain_id:     "chain-#{i}-#{SecureRandom.hex(4)}",
            content_type: ctype,
            content_hash: Digest::SHA256.hexdigest("qbt #{i}")
          )
        end
        results = described_class.query_by_type(content_type: ctype)
        expect(results.size).to eq(2)
        expect(results.map { |r| r[:content_type] }.uniq).to eq([ctype])
      end

      it 'accepts a since: filter' do
        ctype = "spec.since.#{SecureRandom.hex(4)}"
        described_class.append(chain_id: chain_id, content_type: ctype, content_hash: content_hash)
        future = Time.now + 3600
        results = described_class.query_by_type(content_type: ctype, since: future)
        expect(results).to be_empty
      end
    end
  end

  # -------------------------------------------------------------------------
  # Model: AuditRecord (immutability guards)
  # -------------------------------------------------------------------------
  describe Legion::Data::Model::AuditRecord do
    before { skip 'No DB connection' unless Legion::Data.connected? }

    it 'raises on update attempt' do
      Legion::Data::AuditRecord.append(chain_id: chain_id, content_type: content_type, content_hash: content_hash)
      record = Legion::Data::Model::AuditRecord.first(chain_id: chain_id)
      expect { record.update(content_type: 'mutated') }.to raise_error(RuntimeError, /immutable/)
    end

    it 'raises on destroy attempt' do
      Legion::Data::AuditRecord.append(chain_id: chain_id, content_type: content_type, content_hash: content_hash)
      record = Legion::Data::Model::AuditRecord.first(chain_id: chain_id)
      expect { record.destroy }.to raise_error(RuntimeError, /immutable/)
    end

    it 'parses metadata via parsed_metadata' do
      Legion::Data::AuditRecord.append(
        chain_id:     chain_id,
        content_type: content_type,
        content_hash: content_hash,
        metadata:     { key: 'value' }
      )
      record = Legion::Data::Model::AuditRecord.first(chain_id: chain_id)
      expect(record.parsed_metadata[:key]).to eq('value')
    end

    it 'returns empty hash for nil metadata' do
      Legion::Data::AuditRecord.append(chain_id: chain_id, content_type: content_type, content_hash: content_hash)
      record = Legion::Data::Model::AuditRecord.first(chain_id: chain_id)
      expect(record.parsed_metadata).to eq({})
    end
  end
end
