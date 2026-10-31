# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'

RSpec.describe Legion::Data::Local do
  let(:test_db) { 'legionio_local_test.db' }
  let(:resolved_db) { File.join(File.expand_path('~/.legionio'), test_db) }

  before(:each) do
    described_class.reset!
  end

  after(:each) do
    begin
      described_class.shutdown
    rescue StandardError
      nil
    end
    FileUtils.rm_f(resolved_db)
    FileUtils.rm_f(test_db) # cleanup any stale relative path files
  end

  describe '.setup' do
    it 'creates a SQLite connection' do
      described_class.setup(database: test_db)
      expect(described_class.connection).to be_a(Sequel::SQLite::Database)
    end

    it 'sets connected to true' do
      described_class.setup(database: test_db)
      expect(described_class.connected?).to be true
    end

    it 'is idempotent' do
      described_class.setup(database: test_db)
      conn1 = described_class.connection
      described_class.setup(database: test_db)
      expect(described_class.connection).to equal(conn1)
    end

    it 'initializes connection-specific settings on every pooled connection' do
      described_class.setup(database: test_db)
      connection = described_class.connection
      connection.synchronize do
        first = %w[synchronous cache_size mmap_size].map { |pragma| connection.fetch("PRAGMA #{pragma}").single_value }
        second = Thread.new do
          %w[synchronous cache_size mmap_size].map { |pragma| connection.fetch("PRAGMA #{pragma}").single_value }
        end.value

        expect(first).to eq([1, -20_000, 268_435_456])
        expect(second).to eq(first)
      end
    end
  end

  describe '.shutdown' do
    it 'disconnects and clears state' do
      described_class.setup(database: test_db)
      described_class.shutdown
      expect(described_class.connected?).to be false
      expect(described_class.connection).to be_nil
    end
  end

  describe '.db_path' do
    it 'returns the configured database path' do
      described_class.setup(database: test_db)
      expect(described_class.db_path).to eq(resolved_db)
    end
  end

  describe '.register_migrations' do
    it 'accumulates migration directories' do
      described_class.register_migrations(name: :memory, path: '/fake/path')
      described_class.register_migrations(name: :trust, path: '/other/path')
      expect(described_class.registered_migrations.size).to eq(2)
    end

    it 'prevents duplicate registration by name' do
      described_class.register_migrations(name: :memory, path: '/fake/path')
      described_class.register_migrations(name: :memory, path: '/fake/path')
      expect(described_class.registered_migrations.size).to eq(1)
    end
  end

  describe '.model' do
    it 'creates a Sequel::Model bound to local connection' do
      described_class.setup(database: test_db)
      described_class.connection.create_table(:test_items) do
        primary_key :id
        String :name
      end

      model_class = described_class.model(:test_items)
      model_class.create(name: 'hello')
      expect(model_class.count).to eq(1)
      expect(model_class.first.name).to eq('hello')
    end

    it 'raises when not connected' do
      expect { described_class.model(:anything) }.to raise_error(RuntimeError, /not connected/)
    end
  end

  describe 'migration registration and execution' do
    let(:migrations_dir) { File.join(__dir__, 'local', 'test_migrations') }

    before(:each) do
      FileUtils.mkdir_p(migrations_dir)
      File.write(File.join(migrations_dir, '20260316000001_create_test_table.rb'), <<~RUBY)
        Sequel.migration do
          change do
            create_table(:local_test_table) do
              primary_key :id
              String :value
            end
          end
        end
      RUBY
    end

    after(:each) do
      FileUtils.rm_rf(migrations_dir)
    end

    it 'runs registered migrations on setup' do
      described_class.register_migrations(name: :test, path: migrations_dir)
      described_class.setup(database: test_db)
      expect(described_class.connection.table_exists?(:local_test_table)).to be true
    end

    it 'leaves failed startup disconnected and retries pending migrations' do
      broken_migration = File.join(migrations_dir, '20260316000002_broken.rb')
      File.write(broken_migration, "Sequel.migration { change { raise 'broken migration' } }")
      described_class.register_migrations(name: :test, path: migrations_dir)

      expect { described_class.setup(database: test_db) }.to raise_error(RuntimeError, 'broken migration')
      expect(described_class.connected?).to be(false)
      expect(described_class.connection).to be_nil

      File.write(broken_migration, 'Sequel.migration { change { add_column :local_test_table, :recovered, Integer } }')
      described_class.setup(database: test_db)
      expect(described_class.connected?).to be(true)
      expect(described_class.connection[:local_test_table].columns).to include(:recovered)
    end

    it 'propagates migrations registered after startup and clears readiness on failure' do
      described_class.setup(database: test_db)
      described_class.connection.create_table(:local_test_table) { primary_key :id }
      connection = described_class.connection

      expect { described_class.register_migrations(name: :test, path: migrations_dir) }.to raise_error(Sequel::DatabaseError, /already exists/)
      expect(described_class.connected?).to be(false)
      expect(described_class.connection).to be_nil
      expect(connection.pool.size).to eq(0)
    end
  end
end
