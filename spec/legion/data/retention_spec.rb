# frozen_string_literal: true

require 'spec_helper'
require 'legion/data/retention'
require 'tmpdir'

RSpec.describe Legion::Data::Retention do
  let(:db) { Legion::Data.connection }
  let(:table) { :retention_test_records }
  let(:archive_table) { :retention_test_records_archive }

  before(:each) do
    db.drop_table?(table)
    db.drop_table?(archive_table)

    db.create_table(table) do
      primary_key :id
      String :name
      DateTime :created_at
    end
  end

  after(:each) do
    db.drop_table?(archive_table)
    db.drop_table?(table)
  end

  def insert_record(name:, created_at:)
    db[table].insert(name: name, created_at: created_at)
  end

  describe '.archive_table_name' do
    it 'appends _archive suffix as symbol' do
      expect(described_class.archive_table_name(:tasks)).to eq(:tasks_archive)
    end

    it 'works with string input' do
      expect(described_class.archive_table_name('events')).to eq(:events_archive)
    end
  end

  describe '.archive_old_records' do
    it 'moves records older than archive_after_days to archive table' do
      insert_record(name: 'old', created_at: Time.now - (100 * 86_400))
      insert_record(name: 'recent', created_at: Time.now - (10 * 86_400))

      described_class.archive_old_records(table: table, archive_after_days: 90)

      expect(db[table].count).to eq(1)
      expect(db[table].first[:name]).to eq('recent')
      expect(db[archive_table].count).to eq(1)
      expect(db[archive_table].first[:name]).to eq('old')
    end

    it 'returns the correct archived count' do
      insert_record(name: 'old1', created_at: Time.now - (200 * 86_400))
      insert_record(name: 'old2', created_at: Time.now - (150 * 86_400))
      insert_record(name: 'new', created_at: Time.now)

      result = described_class.archive_old_records(table: table, archive_after_days: 90)

      expect(result[:archived]).to eq(2)
      expect(result[:table]).to eq(table)
    end

    it 'returns zero archived when no records are old enough' do
      insert_record(name: 'fresh', created_at: Time.now - (5 * 86_400))

      result = described_class.archive_old_records(table: table, archive_after_days: 90)

      expect(result[:archived]).to eq(0)
    end

    it 'returns zero when no connection' do
      allow(Legion::Data).to receive(:connection).and_return(nil)
      result = described_class.archive_old_records(table: table)
      expect(result[:archived]).to eq(0)
    end

    it 'handles an empty table gracefully' do
      result = described_class.archive_old_records(table: table, archive_after_days: 90)
      expect(result[:archived]).to eq(0)
    end

    it 'creates the archive table automatically if it does not exist' do
      insert_record(name: 'old', created_at: Time.now - (100 * 86_400))

      expect(db.table_exists?(archive_table)).to be false
      described_class.archive_old_records(table: table, archive_after_days: 90)
      expect(db.table_exists?(archive_table)).to be true
    end

    it 'works with a custom date_column' do
      db.drop_table?(table)
      db.create_table(table) do
        primary_key :id
        String :name
        DateTime :recorded_at
      end

      db[table].insert(name: 'old', recorded_at: Time.now - (100 * 86_400))
      db[table].insert(name: 'new', recorded_at: Time.now)

      result = described_class.archive_old_records(
        table:              table,
        date_column:        :recorded_at,
        archive_after_days: 90
      )

      expect(result[:archived]).to eq(1)
      expect(db[archive_table].first[:name]).to eq('old')
    end

    it 'retains committed batches, rolls back a failed batch, and resumes without duplicates' do
      described_class.archive_old_records(table: table)
      old_ids = Array.new(7) { |index| insert_record(name: "old-#{index}", created_at: Time.now - (100 * 86_400)) }
      recent_id = insert_record(name: 'recent', created_at: Time.now)
      db.run <<~SQL
        CREATE TRIGGER fail_archive_batch BEFORE INSERT ON #{archive_table}
        WHEN NEW.id = #{old_ids[3]}
        BEGIN SELECT RAISE(ABORT, 'injected archive failure'); END
      SQL

      expect { described_class.archive_old_records(table: table, batch_size: 2) }.to raise_error(Sequel::DatabaseError)
      expect(db[archive_table].order(:id).select_map(:id)).to eq(old_ids.first(2))
      expect(db[table].order(:id).select_map(:id)).to eq(old_ids.drop(2) + [recent_id])

      db.run('DROP TRIGGER fail_archive_batch')
      expect(described_class.archive_old_records(table: table, batch_size: 2)).to eq(archived: 5, table: table)
      expect(db[archive_table].order(:id).select_map(:id)).to eq(old_ids)
      expect(db[table].select_map(:id)).to eq([recent_id])
    end

    it 'never deletes uncopied rows that become eligible or arrive after selection' do
      described_class.archive_old_records(table: table)
      insert_record(name: 'old', created_at: Time.now - (100 * 86_400))
      insert_record(name: 'newly_old', created_at: Time.now)
      db.run <<~SQL
        CREATE TRIGGER change_retention_candidates AFTER INSERT ON #{archive_table}
        WHEN NEW.name = 'old'
        BEGIN
          UPDATE #{table} SET created_at = '2000-01-01' WHERE name = 'newly_old';
          INSERT INTO #{table} (name, created_at) VALUES ('arrived', '2000-01-01');
        END
      SQL

      expect(described_class.archive_old_records(table: table, batch_size: 1)).to eq(archived: 3, table: table)
      expect(db[archive_table].order(:name).select_map(:name)).to eq(%w[arrived newly_old old])
      expect(db[table].all).to be_empty
    end

    it 'rolls back archive copies when a deletion does not remove every selected row' do
      described_class.archive_old_records(table: table)
      ids = Array.new(2) { |index| insert_record(name: "old-#{index}", created_at: Time.now - (100 * 86_400)) }
      db.run <<~SQL
        CREATE TRIGGER refuse_retention_delete BEFORE DELETE ON #{table}
        WHEN OLD.id = #{ids.first}
        BEGIN SELECT RAISE(IGNORE); END
      SQL

      expect { described_class.archive_old_records(table: table, batch_size: 2) }.to raise_error(Sequel::Error)
      expect(db[table].order(:id).select_map(:id)).to eq(ids)
      expect(db[archive_table].all).to be_empty
    end

    it 'rejects an unbounded batch size without moving records' do
      id = insert_record(name: 'old', created_at: Time.now - (100 * 86_400))

      expect { described_class.archive_old_records(table: table, batch_size: nil) }.to raise_error(ArgumentError)
      expect(db[table].select_map(:id)).to eq([id])
      expect(db.table_exists?(archive_table)).to be false
    end

    it 'requires a declared primary key rather than deleting ambiguous identities' do
      db.drop_table(table)
      db.create_table(table) do
        Integer :id
        DateTime :created_at
      end
      row = { id: 1, created_at: Time.now - (100 * 86_400) }
      db[table].multi_insert([row, row])

      expect { described_class.archive_old_records(table: table) }.to raise_error(Sequel::Error)
      expect(db[table].count).to eq(2)
      expect(db.table_exists?(archive_table)).to be false
    end

    it 'preserves complete composite identities beyond SQLite expression-depth limits' do
      db.drop_table(table)
      db.create_table(table) do
        Integer :tenant_id, null: false
        Integer :entry_id, null: false
        DateTime :created_at
        primary_key %i[tenant_id entry_id]
      end
      old = Time.now - (100 * 86_400)
      ids = (1..1001).to_a
      db[table].multi_insert(ids.map { |id| { tenant_id: 1, entry_id: id, created_at: old } })
      db[table].insert(tenant_id: 2, entry_id: 1, created_at: Time.now)

      expect(described_class.archive_old_records(table: table)).to eq(archived: ids.length, table: table)
      expect(db[archive_table].order(:entry_id).select_map(%i[tenant_id entry_id])).to eq(ids.map { |id| [1, id] })
      expect(db[table].select_map(%i[tenant_id entry_id])).to eq([[2, 1]])
    end

    it 'lets independent processes archive each row once, including concurrent first use' do
      workers = []
      pending_pids = []
      gate_reader = nil
      gate_writer = nil
      database = nil
      Dir.mktmpdir('legion-retention-spec') do |directory|
        path = File.join(directory, 'retention.db')
        database = Sequel.sqlite(path, timeout: 5000)
        database.create_table(table) do
          primary_key :id
          String :name
          DateTime :created_at
        end
        database[table].multi_insert(Array.new(101) { |id| { name: "row-#{id}", created_at: Time.now - (100 * 86_400) } })
        database.disconnect
        gate_reader, gate_writer = IO.pipe
        2.times do
          reader, writer = IO.pipe
          pid = Process.fork do
            reader.close
            gate_writer.close
            connection = Sequel.sqlite(path, timeout: 5000)
            Legion::Data::Connection.sequel = connection
            gate_reader.read(1)
            result = described_class.archive_old_records(table: table, batch_size: 7)
            writer.write(result.fetch(:archived).to_s)
            writer.close
            Process.exit!(0)
          rescue StandardError => e
            warn("Retention worker failed: #{e.class}: #{e.message}")
            Process.exit!(1)
          end
          writer.close
          pending_pids << pid
          workers << [pid, reader]
        end
        gate_reader.close
        gate_writer.write('go')
        gate_writer.close
        counts = workers.map do |pid, reader|
          output = reader.read
          reader.close
          status = Process.wait2(pid).last
          pending_pids.delete(pid)
          expect(status).to be_success
          Integer(output)
        end

        expect(counts.sum).to eq(101)
        expect(database[table].all).to be_empty
        expect(database[archive_table].order(:id).select_map(:id)).to eq((1..101).to_a)
      ensure
        [gate_reader, gate_writer, *workers.map(&:last)].compact.each { |io| io.close unless io.closed? }
        pending_pids.each { |pid| Process.wait(pid) }
        database&.disconnect
      end
    end
  end

  describe '.purge_expired_records' do
    before(:each) do
      db.create_table(archive_table) do
        primary_key :id
        String :name
        DateTime :created_at
        DateTime :archived_at
      end
    end

    it 'deletes records from archive older than retention_years' do
      db[archive_table].insert(name: 'ancient', created_at: Time.now - (8 * 365 * 86_400))
      db[archive_table].insert(name: 'recent_archive', created_at: Time.now - (2 * 365 * 86_400))

      result = described_class.purge_expired_records(table: table, retention_years: 7)

      expect(result[:purged]).to eq(1)
      expect(db[archive_table].count).to eq(1)
      expect(db[archive_table].first[:name]).to eq('recent_archive')
    end

    it 'returns the correct purged count' do
      db[archive_table].insert(name: 'old1', created_at: Time.now - (10 * 365 * 86_400))
      db[archive_table].insert(name: 'old2', created_at: Time.now - (9 * 365 * 86_400))

      result = described_class.purge_expired_records(table: table, retention_years: 7)

      expect(result[:purged]).to eq(2)
      expect(result[:table]).to eq(table)
    end

    it 'returns zero when archive table does not exist' do
      db.drop_table?(archive_table)
      result = described_class.purge_expired_records(table: table, retention_years: 7)
      expect(result[:purged]).to eq(0)
    end

    it 'handles an empty archive table gracefully' do
      result = described_class.purge_expired_records(table: table, retention_years: 7)
      expect(result[:purged]).to eq(0)
    end

    it 'works with a custom date_column' do
      db.drop_table?(archive_table)
      db.create_table(archive_table) do
        primary_key :id
        String :name
        DateTime :recorded_at
        DateTime :archived_at
      end

      db[archive_table].insert(name: 'ancient', recorded_at: Time.now - (8 * 365 * 86_400))
      db[archive_table].insert(name: 'recent', recorded_at: Time.now - (1 * 365 * 86_400))

      result = described_class.purge_expired_records(
        table:           table,
        date_column:     :recorded_at,
        retention_years: 7
      )

      expect(result[:purged]).to eq(1)
      expect(db[archive_table].first[:name]).to eq('recent')
    end
  end

  describe '.retention_status' do
    it 'reports correct active and archived counts' do
      db.create_table(archive_table) do
        primary_key :id
        String :name
        DateTime :created_at
        DateTime :archived_at
      end

      insert_record(name: 'active1', created_at: Time.now)
      insert_record(name: 'active2', created_at: Time.now)
      db[archive_table].insert(name: 'arch1', created_at: Time.now - (200 * 86_400))

      status = described_class.retention_status(table: table)

      expect(status[:table]).to eq(table)
      expect(status[:active_count]).to eq(2)
      expect(status[:archived_count]).to eq(1)
    end

    it 'returns nil for oldest_active when table is empty' do
      status = described_class.retention_status(table: table)
      expect(status[:oldest_active]).to be_nil
    end

    it 'returns nil for oldest_archived when archive table does not exist' do
      status = described_class.retention_status(table: table)
      expect(status[:archived_count]).to eq(0)
      expect(status[:oldest_archived]).to be_nil
    end
  end
end
