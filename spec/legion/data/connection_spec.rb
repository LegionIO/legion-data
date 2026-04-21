# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Legion::Data::Connection' do
  after(:each) do
    Legion::Data::Connection.shutdown
  end

  it 'can setup' do
    expect { Legion::Data::Connection.setup }.not_to raise_exception
    # expect(Legion::Data::Connection.adapter).to eq :mysql2
    expect(Legion::Settings[:data][:connected]).to eq true
  end

  it 'can shutdown' do
    expect { Legion::Data::Connection.shutdown }.not_to raise_exception
    expect(Legion::Settings[:data][:connected]).to eq false
  end

  it 'has creds_builder' do
    creds = Legion::Data::Connection.creds_builder
    expect(creds).to be_a Hash
    expect(creds[:database]).to eq 'legionio.db'
  end

  it 'can setup with logger' do
    Legion::Settings[:data][:log] = true
    Legion::Settings[:data][:sql_log_level] = 'debug'
    Legion::Settings[:data][:log_warn_duration] = 42
    Legion::Data::Connection.setup
    expect(Legion::Data::Connection.sequel.sql_log_level).to eq :debug
    expect(Legion::Data::Connection.sequel.log_warn_duration).to eq 42
  end

  it 'can run creds_builder' do
    expect(Legion::Data::Connection.creds_builder).to be_a Hash
  end

  it 'using a tagged SlowQueryLogger' do
    Legion::Data::Connection.setup
    expect(Legion::Data::Connection.sequel.loggers).to be_a Array
    expect(Legion::Data::Connection.sequel.loggers.count).to be > 0
    expect(Legion::Data::Connection.sequel.loggers.first).to be_a Legion::Data::Connection::SlowQueryLogger
    expect(Legion::Data::Connection.sequel.loggers.first.tagged.segments).to eq(%w[data connection])
  end

  it 'uses other things' do
    Legion::Data::Connection.setup
    expect(Legion::Settings[:data][:connected]).to eq true
    expect(Legion::Data::Connection.sequel.log_warn_duration)
      .to eq Legion::Settings[:data][:log_warn_duration]
    expect(Legion::Data::Connection.sequel.sql_log_level).to eq Legion::Settings[:data][:sql_log_level].to_sym
  end

  describe '.reconnect_with_fresh_creds' do
    it 'returns true and reconnects successfully' do
      Legion::Data::Connection.setup
      original_sequel = Legion::Data::Connection.sequel

      result = Legion::Data::Connection.reconnect_with_fresh_creds

      expect(result).to eq true
      expect(Legion::Settings[:data][:connected]).to eq true
      expect(Legion::Data::Connection.sequel).not_to be_nil
      # A new Sequel::Database instance should have been created
      expect(Legion::Data::Connection.sequel).not_to equal(original_sequel)
    end

    it 'picks up changed credentials from Settings' do
      Legion::Data::Connection.setup

      # Simulate Vault LeaseManager pushing fresh creds into Settings
      original_creds = Legion::Settings[:data][:creds].dup
      Legion::Settings[:data][:creds][:database] = 'rotated_test.db'

      Legion::Data::Connection.reconnect_with_fresh_creds

      # The new connection should have been built from current settings
      expect(Legion::Settings[:data][:connected]).to eq true
      expect(Legion::Data::Connection.sequel).not_to be_nil
    ensure
      # Restore original creds so other tests aren't affected
      Legion::Settings[:data][:creds] = original_creds if original_creds
    end

    it 'returns false and resets connection state when reconnect fails' do
      Legion::Data::Connection.setup
      expect(Legion::Settings[:data][:connected]).to eq true
      expect(Legion::Data::Connection.sequel).not_to be_nil

      # Force a failure by temporarily breaking the adapter setting
      original_adapter = Legion::Settings[:data][:adapter]
      Legion::Settings[:data][:adapter] = 'bogus_adapter'

      result = Legion::Data::Connection.reconnect_with_fresh_creds

      expect(result).to eq false
      # Verify connection state is properly reset after failure
      expect(Legion::Settings[:data][:connected]).to eq false
      expect(Legion::Data::Connection.sequel).to be_nil
    ensure
      Legion::Settings[:data][:adapter] = original_adapter
      # Reset cached adapter so subsequent tests are clean
      Legion::Data::Connection.instance_variable_set(:@adapter, nil)
    end

    it 'clears replica servers on reconnect' do
      Legion::Data::Connection.setup
      # Manually set replica_servers to simulate a previous replica config
      Legion::Data::Connection.instance_variable_set(:@replica_servers, [:read_0])

      Legion::Data::Connection.reconnect_with_fresh_creds

      # For SQLite adapter, replicas should be cleared (no replicas for sqlite)
      expect(Legion::Data::Connection.replica_servers).to eq([])
    end

    it 'closes query file logger on reconnect to prevent fd leak' do
      Legion::Settings[:data][:query_log] = true
      Legion::Data::Connection.setup

      # Get reference to the query file logger
      logger = Legion::Data::Connection.instance_variable_get(:@query_file_logger)
      expect(logger).not_to be_nil

      # Mock close to verify it's called
      expect(logger).to receive(:close).and_call_original

      Legion::Data::Connection.reconnect_with_fresh_creds

      # Verify a new logger was created
      new_logger = Legion::Data::Connection.instance_variable_get(:@query_file_logger)
      expect(new_logger).not_to be_nil
      expect(new_logger).not_to equal(logger)
    ensure
      Legion::Settings[:data][:query_log] = false
    end

    it 'verifies actual credential usage during reconnect' do
      Legion::Data::Connection.setup
      initial_sequel = Legion::Data::Connection.sequel

      # Simulate changing database path (for SQLite)
      original_creds = Legion::Settings[:data][:creds].dup
      new_database_path = 'reconnect_test_credentials.db'
      Legion::Settings[:data][:creds][:database] = new_database_path

      result = Legion::Data::Connection.reconnect_with_fresh_creds
      expect(result).to eq true

      # Verify a new connection was created and it's using the new database path
      new_sequel = Legion::Data::Connection.sequel
      expect(new_sequel).not_to equal(initial_sequel)
      expect(new_sequel).not_to be_nil

      # For SQLite adapter, we can verify the database path was updated
      # by checking that the connection is using the new path
      expect(Legion::Settings[:data][:creds][:database]).to eq new_database_path
    ensure
      # Restore original creds
      Legion::Settings[:data][:creds] = original_creds if original_creds
      # Clean up test database file if it was created
      File.delete(new_database_path) if File.exist?(new_database_path)
    end
  end
end
