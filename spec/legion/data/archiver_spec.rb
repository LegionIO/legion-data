# frozen_string_literal: true

require 'spec_helper'
require 'digest'
require 'json'
require 'stringio'
require 'tmpdir'
require 'zlib'
require 'legion/data/archiver'

RSpec.describe Legion::Data::Archiver do
  let(:conn) { Legion::Data.connection }

  before(:each) do
    @archive_dir = Dir.mktmpdir('legion-archive-spec')
    allow(Dir).to receive(:tmpdir).and_return(@archive_dir)
    allow(Legion::Data::Connection).to receive(:adapter).and_return(:postgres)
    allow(Legion::Data).to receive(:connection).and_return(conn)
  end

  after(:each) do
    FileUtils.remove_entry(@archive_dir)
  end

  # --- non-postgres guard ---

  describe '.archive_table non-postgres' do
    it 'returns skipped true with reason not_postgres on sqlite' do
      allow(Legion::Data::Connection).to receive(:adapter).and_return(:sqlite)
      result = described_class.archive_table(table: :tasks)
      expect(result).to eq({ skipped: true, reason: 'not_postgres' })
    end

    it 'returns skipped true with reason not_postgres on mysql2' do
      allow(Legion::Data::Connection).to receive(:adapter).and_return(:mysql2)
      result = described_class.archive_table(table: :tasks)
      expect(result).to eq({ skipped: true, reason: 'not_postgres' })
    end
  end

  # --- empty table ---

  describe '.archive_table with empty/no old rows' do
    let(:table) { :archiver_test_empty }

    before(:each) do
      conn.drop_table?(table)
      conn.create_table(table) do
        primary_key :id
        String :name
        DateTime :created_at
      end
    end

    after(:each) do
      conn.drop_table?(table)
    end

    it 'returns zero batches when no rows are old enough' do
      conn[table].insert(name: 'fresh', created_at: Time.now - (5 * 86_400))
      result = described_class.archive_table(table: table, retention_days: 90, storage_backend: nil)
      expect(result[:batches]).to eq(0)
      expect(result[:total_rows]).to eq(0)
      expect(result[:paths]).to eq([])
    end

    it 'returns zero batches for an empty table' do
      result = described_class.archive_table(table: table, retention_days: 90, storage_backend: nil)
      expect(result[:batches]).to eq(0)
      expect(result[:total_rows]).to eq(0)
    end
  end

  # --- single batch ---

  describe '.archive_table single batch' do
    let(:table) { :archiver_test_single }

    before(:each) do
      conn.drop_table?(:archive_manifest)
      conn.drop_table?(table)

      conn.create_table(table) do
        primary_key :id
        String :name
        DateTime :created_at
      end

      conn.create_table(:archive_manifest) do
        primary_key :id
        String :batch_id, null: false, unique: true
        String :source_table, null: false
        Integer :row_count, null: false
        String :checksum, null: false
        String :storage_path, null: false
        DateTime :archived_at, null: false, default: Sequel::CURRENT_TIMESTAMP
        String :metadata
      end
    end

    after(:each) do
      conn.drop_table?(:archive_manifest)
      conn.drop_table?(table)
    end

    def insert_old(name)
      conn[table].insert(name: name, created_at: Time.now - (100 * 86_400))
    end

    it 'JSONL structure is correct: each line is valid JSON with original fields' do
      insert_old('alpha')
      insert_old('beta')

      result = described_class.archive_table(table: table, retention_days: 90, storage_backend: nil)
      expect(result[:total_rows]).to eq(2)

      path = result[:paths].first.sub('file://', '')
      compressed = File.binread(path)
      jsonl = Zlib::GzipReader.new(StringIO.new(compressed)).read
      lines = jsonl.split("\n").reject(&:empty?)
      expect(lines.size).to eq(2)
      parsed = lines.map { |l| JSON.parse(l) }
      names = parsed.map { |p| p['name'] }
      expect(names).to contain_exactly('alpha', 'beta')
    end

    it 'SHA-256 checksum in manifest matches compressed file data' do
      insert_old('delta')

      described_class.archive_table(table: table, retention_days: 90, storage_backend: nil)

      manifest_row = conn[:archive_manifest].first
      path = manifest_row[:storage_path].sub('file://', '')
      compressed = File.binread(path)
      expect(manifest_row[:checksum]).to eq(Digest::SHA256.hexdigest(compressed))
    end

    it 'deletes rows from source table after archiving' do
      3.times { |i| insert_old("row#{i}") }
      conn[table].insert(name: 'fresh', created_at: Time.now - (5 * 86_400))

      described_class.archive_table(table: table, retention_days: 90, storage_backend: nil)

      expect(conn[table].count).to eq(1)
      expect(conn[table].first[:name]).to eq('fresh')
    end

    it 'preserves both archives across separate runs in the same month' do
      insert_old('first archive')
      described_class.archive_table(table: table, storage_backend: nil)
      insert_old('second archive')
      described_class.archive_table(table: table, storage_backend: nil)

      manifests = conn[:archive_manifest].order(:id).all
      expect(manifests.map { |row| row[:storage_path] }.uniq.size).to eq(2)
      names = manifests.map do |manifest|
        path = manifest[:storage_path].delete_prefix('file://')
        expect(File.basename(path)).to eq("batch_#{manifest[:batch_id]}.jsonl.gz")
        expect(Digest::SHA256.file(path).hexdigest).to eq(manifest[:checksum])
        Zlib::GzipReader.open(path) { |file| Legion::JSON.load(file.read)[:name] }
      end
      expect(names).to eq(['first archive', 'second archive'])
    end

    it 'retention_days boundary: rows exactly at cutoff are included' do
      boundary = Time.now - (90 * 86_400) - 1
      conn[table].insert(name: 'boundary_old', created_at: boundary)
      conn[table].insert(name: 'boundary_fresh', created_at: Time.now - (89 * 86_400))

      result = described_class.archive_table(table: table, retention_days: 90, storage_backend: nil)

      expect(result[:total_rows]).to eq(1)
      expect(conn[table].first[:name]).to eq('boundary_fresh')
    end
  end

  # --- batch_size respected ---

  describe '.archive_table batch_size' do
    let(:table) { :archiver_test_batches }

    before(:each) do
      conn.drop_table?(:archive_manifest)
      conn.drop_table?(table)

      conn.create_table(table) do
        primary_key :id
        String :name
        DateTime :created_at
      end

      conn.create_table(:archive_manifest) do
        primary_key :id
        String :batch_id, null: false, unique: true
        String :source_table, null: false
        Integer :row_count, null: false
        String :checksum, null: false
        String :storage_path, null: false
        DateTime :archived_at, null: false, default: Sequel::CURRENT_TIMESTAMP
        String :metadata
      end

      5.times { |i| conn[table].insert(name: "old#{i}", created_at: Time.now - (100 * 86_400)) }
    end

    after(:each) do
      conn.drop_table?(:archive_manifest)
      conn.drop_table?(table)
    end

    it 'iterates multiple batches when batch_size < total rows' do
      result = described_class.archive_table(table: table, retention_days: 90, batch_size: 2, storage_backend: nil)
      expect(result[:batches]).to eq(3)
      expect(result[:total_rows]).to eq(5)
      expect(conn[table].count).to eq(0)
    end

    it 'produces one batch when batch_size >= total rows' do
      result = described_class.archive_table(table: table, retention_days: 90, batch_size: 10, storage_backend: nil)
      expect(result[:batches]).to eq(1)
      expect(result[:total_rows]).to eq(5)
    end
  end

  # --- transaction rollback ---

  describe '.archive_table transaction rollback' do
    let(:table) { :archiver_test_rollback }

    before(:each) do
      conn.drop_table?(table)
      conn.create_table(table) do
        primary_key :id
        String :name
        DateTime :created_at
      end
      conn[table].insert(name: 'old', created_at: Time.now - (100 * 86_400))
    end

    after(:each) do
      conn.drop_table?(table)
    end

    it 'rolls back row deletion when manifest insert fails' do
      allow(conn).to receive(:[]).and_call_original
      mock_manifest = double('manifest_dataset')
      allow(conn).to receive(:[]).with(:archive_manifest).and_return(mock_manifest)
      allow(mock_manifest).to receive(:insert).and_raise(StandardError, 'manifest insert failure')

      expect do
        described_class.archive_table(table: table, retention_days: 90, storage_backend: nil)
      end.to raise_error(StandardError, /manifest insert failure/)

      expect(conn[table].count).to eq(1)
    end
  end

  # --- upload backends ---

  describe '.upload_batch' do
    let(:compressed_data) { Zlib::Deflate.deflate('test data') }
    let(:batch_id) { SecureRandom.uuid }

    it 'nil backend writes to tmpdir and returns file:// path' do
      path = described_class.upload_batch(
        data: compressed_data, table: 'tasks', year: 2026, month: 3, batch_id: batch_id, backend: nil
      )
      expect(path).to start_with('file://')
      expect(File.binread(path.delete_prefix('file://'))).to eq(compressed_data)
    end

    it 'preserves distinct S3 objects and returns their retrievable paths' do
      objects = {}
      stub_const('Legion::Extensions::S3::Runners::Put', Class.new)
      allow(Legion::Extensions::S3::Runners::Put).to receive(:run) { |key:, body:| objects[key] = body }

      paths = %w[first second].map do |body|
        described_class.upload_batch(data: body, table: 'tasks', year: 2026, month: 3, batch_id: SecureRandom.uuid, backend: :s3)
      end
      expect(paths.map { |path| objects.fetch(path.delete_prefix('s3://')) }).to eq(%w[first second])
    end

    it 'preserves distinct Azure blobs and returns their retrievable paths' do
      objects = {}
      stub_const('Legion::Extensions::AzureStorage::Runners::Upload', Class.new)
      allow(Legion::Extensions::AzureStorage::Runners::Upload).to receive(:run) { |blob_name:, data:| objects[blob_name] = data }

      paths = %w[first second].map do |body|
        described_class.upload_batch(data: body, table: 'tasks', year: 2026, month: 3, batch_id: SecureRandom.uuid, backend: :azure)
      end
      expect(paths.map { |path| objects.fetch(path.delete_prefix('azure://')) }).to eq(%w[first second])
    end

    it 'raises UploadError when s3 runner not defined' do
      hide_const('Legion::Extensions::S3::Runners::Put') if defined?(Legion::Extensions::S3::Runners::Put)
      expect do
        described_class.upload_batch(
          data: compressed_data, table: 'tasks', year: 2026, month: 3, batch_id: batch_id, backend: :s3
        )
      end.to raise_error(Legion::Data::Archiver::UploadError)
    end

    it 'raises UploadError when azure runner not defined' do
      hide_const('Legion::Extensions::AzureStorage::Runners::Upload') if defined?(Legion::Extensions::AzureStorage::Runners::Upload)
      expect do
        described_class.upload_batch(
          data: compressed_data, table: 'tasks', year: 2026, month: 3, batch_id: batch_id, backend: :azure
        )
      end.to raise_error(Legion::Data::Archiver::UploadError)
    end

    it 'raises UploadError when s3 runner raises' do
      stub_const('Legion::Extensions::S3::Runners::Put', Class.new)
      allow(Legion::Extensions::S3::Runners::Put).to receive(:run).and_raise(StandardError, 'connection refused')

      expect do
        described_class.upload_batch(
          data: compressed_data, table: 'tasks', year: 2026, month: 3, batch_id: batch_id, backend: :s3
        )
      end.to raise_error(Legion::Data::Archiver::UploadError, /connection refused/)
    end
  end

  # --- manifest_stats ---

  describe '.manifest_stats' do
    before(:each) do
      conn.drop_table?(:archive_manifest)
    end

    after(:each) do
      conn.drop_table?(:archive_manifest)
    end

    it 'returns empty hash when archive_manifest table does not exist' do
      result = described_class.manifest_stats
      expect(result).to eq({})
    end

    it 'returns empty hash when no manifest rows exist' do
      conn.create_table(:archive_manifest) do
        primary_key :id
        String :batch_id, null: false, unique: true
        String :source_table, null: false
        Integer :row_count, null: false
        String :checksum, null: false
        String :storage_path, null: false
        DateTime :archived_at, null: false, default: Sequel::CURRENT_TIMESTAMP
        String :metadata
      end

      result = described_class.manifest_stats
      expect(result).to eq({})
    end

    it 'returns aggregated stats per source_table' do
      conn.create_table(:archive_manifest) do
        primary_key :id
        String :batch_id, null: false, unique: true
        String :source_table, null: false
        Integer :row_count, null: false
        String :checksum, null: false
        String :storage_path, null: false
        DateTime :archived_at, null: false, default: Sequel::CURRENT_TIMESTAMP
        String :metadata
      end

      now = Time.now.utc
      conn[:archive_manifest].insert(
        batch_id: SecureRandom.uuid, source_table: 'tasks',
        row_count: 500, checksum: 'abc', storage_path: 'file:///tmp/1', archived_at: now - 86_400
      )
      conn[:archive_manifest].insert(
        batch_id: SecureRandom.uuid, source_table: 'tasks',
        row_count: 300, checksum: 'def', storage_path: 'file:///tmp/2', archived_at: now
      )
      conn[:archive_manifest].insert(
        batch_id: SecureRandom.uuid, source_table: 'audit_log',
        row_count: 100, checksum: 'ghi', storage_path: 'file:///tmp/3', archived_at: now
      )

      result = described_class.manifest_stats
      expect(result.keys).to contain_exactly('tasks', 'audit_log')
      expect(result['tasks'][:batches]).to eq(2)
      expect(result['tasks'][:total_rows]).to eq(800)
      expect(result['audit_log'][:batches]).to eq(1)
      expect(result['audit_log'][:total_rows]).to eq(100)
    end

    it 'returns skipped hash on non-postgres' do
      allow(Legion::Data::Connection).to receive(:adapter).and_return(:sqlite)
      result = described_class.manifest_stats
      expect(result).to eq({})
    end
  end
end
