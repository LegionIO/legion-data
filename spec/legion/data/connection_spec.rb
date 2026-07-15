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

  describe 'connection_validation default' do
    it 'defaults to false — the validator pings SELECT NULL on every checkout/checkin and kills throughput' do
      expect(Legion::Data::Settings.default[:connection_validation]).to eq(false)
    end
  end

  describe 'connection_validation_timeout default' do
    it 'defaults to -1 so every checkout validates liveness when validation is enabled' do
      expect(Legion::Data::Settings.default[:connection_validation_timeout]).to eq(-1)
    end
  end

  describe 'preconnect default' do
    it 'defaults to false to avoid background thread noise on failed network connects' do
      expect(Legion::Data::Settings.default[:preconnect]).to eq(false)
    end
  end

  describe 'unresolved URI placeholder detection' do
    before do
      Legion::Settings[:data][:adapter] = 'postgres'
    end

    after do
      Legion::Data::Connection.shutdown
      Legion::Settings[:data][:adapter] = 'sqlite'
      Legion::Settings[:data][:dev_mode] = true
      Legion::Settings[:data][:dev_fallback] = false
      Legion::Settings[:data][:creds] = { database: 'legion_test.db' }
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
        @query_log_path = File.join(dir, 'query.log')
        example.run
      end
    end

    it 'ignores debug writes after close without warning' do
      logger = described_class.new(@query_log_path)
      logger.close

      expect(logger).not_to receive(:handle_exception)
      expect { logger.debug('SELECT 1') }.not_to raise_error
    end

    it 'allows repeated close calls' do
      logger = described_class.new(@query_log_path)

      expect { 2.times { logger.close } }.not_to raise_error
    end
  end
end
