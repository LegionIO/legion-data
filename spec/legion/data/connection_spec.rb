# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

RSpec.describe 'Legion::Data::Connection' do
  after(:each) do
    Legion::Data::Connection.shutdown
  end

  it 'can setup' do
    expect { Legion::Data::Connection.setup }.not_to raise_error
    # expect(Legion::Data::Connection.adapter).to eq :mysql2
    expect(Legion::Settings[:data][:connected]).to eq true
  end

  it 'can shutdown' do
    expect { Legion::Data::Connection.shutdown }.not_to raise_error
    expect(Legion::Settings[:data][:connected]).to eq false
  end

  it 'has creds_builder' do
    creds = Legion::Data::Connection.creds_builder
    expect(creds).to be_a Hash
    expect(creds[:database]).to eq Legion::Settings[:data][:creds][:database]
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

  describe 'unresolved URI placeholder detection' do
    before do
      @original_connection = Legion::Data::Connection.sequel
      @original_adapter = Legion::Data::Connection.instance_variable_get(:@adapter)
      Legion::Data::Connection.sequel = nil
      Legion::Settings[:data][:adapter] = 'postgres'
    end

    after do
      Legion::Data::Connection.shutdown
      Legion::Settings[:data][:adapter] = 'sqlite'
      Legion::Settings[:data][:dev_mode] = true
      Legion::Settings[:data][:dev_fallback] = false
      Legion::Settings[:data][:creds] = { database: 'legion_test.db' }
      Legion::Data::Connection.sequel = @original_connection
      Legion::Data::Connection.instance_variable_set(:@adapter, @original_adapter)
    end

    it 'raises UnresolvedCredentialError when username contains a lease:// URI' do
      Legion::Settings[:data][:creds] = {
        user:     'lease://postgresql#username',
        password: 'resolved_password',
        host:     '127.0.0.1',
        port:     5432,
        database: 'legionio'
      }

      expect { Legion::Data::Connection.setup }.to raise_error(
        Legion::Data::Connection::UnresolvedCredentialError,
        %r{settings\[:data\]\[:creds\]\[:user\].*unresolved URI placeholder.*lease://postgresql#username}
      )
    end

    it 'raises UnresolvedCredentialError when password contains a vault:// URI' do
      Legion::Settings[:data][:creds] = {
        user:     'legion',
        password: 'vault://secret/db#password',
        host:     '127.0.0.1',
        port:     5432,
        database: 'legionio'
      }

      expect { Legion::Data::Connection.setup }.to raise_error(
        Legion::Data::Connection::UnresolvedCredentialError,
        %r{settings\[:data\]\[:creds\]\[:password\].*unresolved URI placeholder.*vault://secret/db#password}
      )
    end

    it 'raises UnresolvedCredentialError when password contains an env:// URI' do
      Legion::Settings[:data][:creds] = {
        user:     'legion',
        password: 'env://DB_PASSWORD',
        host:     '127.0.0.1',
        port:     5432,
        database: 'legionio'
      }

      expect { Legion::Data::Connection.setup }.to raise_error(
        Legion::Data::Connection::UnresolvedCredentialError,
        %r{settings\[:data\]\[:creds\]\[:password\].*unresolved URI placeholder.*env://DB_PASSWORD}
      )
    end

    it 'does not raise when credentials are resolved strings' do
      Legion::Settings[:data][:creds] = {
        user:     'legion',
        password: 'actual_password',
        host:     '127.0.0.1',
        port:     5432,
        database: 'legionio'
      }

      opts = Legion::Data::Connection.send(:sequel_opts)
      expect do
        Legion::Data::Connection.send(:connection_opts_for, adapter: :postgres, opts: opts)
      end.not_to raise_error
    end
  end

  describe Legion::Data::Connection::QueryFileLogger do
    around do |example|
      Dir.mktmpdir('legion-data-query-log') do |dir|
        logger = described_class.new(File.join(dir, 'query.log'))
        database = Sequel.sqlite
        database.create_table(:query_log_probe) do
          primary_key :id
          String :value, unique: true
        end
        database.loggers << logger
        @query_logger = logger
        @query_database = database
        example.run
      ensure
        logger&.close
        database&.disconnect
      end
    end

    it 'preserves a successful commit when the query log disk is full' do
      allow(@query_logger.instance_variable_get(:@file)).to receive(:puts).and_raise(Errno::ENOSPC)
      allow(@query_logger).to receive(:handle_exception)

      id = @query_database[:query_log_probe].insert(value: 'committed')
      expect(@query_database[:query_log_probe][id: id][:value]).to eq('committed')
      expect(@query_logger).to have_received(:handle_exception).with(
        an_instance_of(Errno::ENOSPC), hash_including(operation: :query_file_write, handled: true)
      ).at_least(:once)
    end

    it 'preserves the original database error when query logging also fails' do
      @query_database[:query_log_probe].insert(value: 'duplicate')
      allow(@query_logger.instance_variable_get(:@file)).to receive(:puts).and_raise(Errno::EIO)
      allow(@query_logger).to receive(:handle_exception)

      expect { @query_database[:query_log_probe].insert(value: 'duplicate') }.to raise_error(Sequel::UniqueConstraintViolation)
      expect(@query_database[:query_log_probe].count).to eq(1)
    end

    it 'permits database operations after repeated logger shutdown without warnings' do
      2.times { @query_logger.close }
      expect(@query_logger).not_to receive(:handle_exception)
      id = @query_database[:query_log_probe].insert(value: 'after close')
      expect(@query_database[:query_log_probe][id: id][:value]).to eq('after close')
    end

    it 'reports close errors without breaking database operations or later shutdown' do
      file = @query_logger.instance_variable_get(:@file)
      allow(file).to receive(:close).and_wrap_original do |close|
        close.call
        raise IOError, 'flush failed'
      end
      allow(@query_logger).to receive(:handle_exception)

      @query_logger.close
      id = @query_database[:query_log_probe].insert(value: 'after failed flush')
      expect(@query_database[:query_log_probe][id: id][:value]).to eq('after failed flush')
      expect(@query_logger).to have_received(:handle_exception).with(
        an_instance_of(IOError), hash_including(operation: :query_file_close, handled: true)
      )
    end
  end
end
