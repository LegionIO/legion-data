# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

RSpec.describe 'Database initialization failures' do
  around do |example|
    settings = Legion::Settings[:data]
    original_settings = settings.dup
    original_connection = Legion::Data::Connection.sequel
    original_adapter = Legion::Data::Connection.instance_variable_get(:@adapter)
    begin
      Dir.mktmpdir('legion-data-initialization') do |dir|
        @database_path = File.join(dir, 'shared.db')
        settings.merge!(adapter: 'sqlite', connected: false, creds: { database: @database_path },
                        readonly: false, log: false, query_log: false, shutdown_timeout: 0,
                        migrations: settings[:migrations].merge(auto_migrate: true, ran: false),
                        models: settings[:models].merge(autoload: false, loaded: false),
                        local: settings[:local].merge(enabled: false))
        Legion::Data::Connection.sequel = nil
        @databases = []
        begin
          example.run
        ensure
          Legion::Data::Connection.shutdown
          @databases.each(&:disconnect)
        end
      end
    ensure
      settings.replace(original_settings)
      Legion::Data::Connection.sequel = original_connection
      Legion::Data::Connection.instance_variable_set(:@adapter, original_adapter)
    end
  end

  before do
    allow(Legion::Data::Local).to receive(:connected?).and_return(false)
    allow(Sequel).to receive(:connect).and_wrap_original do |connect, *args, **options|
      database = connect.call(*args, **options)
      @databases << database
      database
    end
  end

  it 'propagates migration failure, releases the pool, and permits a successful retry' do
    Sequel.sqlite(@database_path).disconnect
    Legion::Settings[:data][:readonly] = true
    expect { Legion::Data.setup }.to raise_error(Sequel::DatabaseError, /readonly/)
    expect(Legion::Data.connected?).to be(false)
    expect(Legion::Data.connection).to be_nil
    expect(@databases.last.pool.size).to eq(0)

    Legion::Settings[:data][:readonly] = false
    Legion::Data.setup
    expect(Legion::Data.connected?).to be(true)
    expect(Legion::Data.connection.table_exists?(:tasks)).to be(true)
  end

  it 'does not retain a connection after model loading fails' do
    Legion::Settings[:data][:models][:autoload] = true
    allow(Legion::Data::Models).to receive(:load).and_raise(LoadError, 'model dependency unavailable')
    expect { Legion::Data.setup_global }.to raise_error(LoadError, /model dependency/)
    expect(Legion::Data.connected?).to be(false)
    expect(Legion::Settings[:data][:models][:loaded]).to be(false)
    expect(Legion::Data.connection).to be_nil
    expect(@databases.last.pool.size).to eq(0)
  end

  it 'propagates connection configuration failures instead of reporting connected' do
    allow(Legion::Data::Connection).to receive(:configure_extensions).and_raise(Sequel::Error, 'configuration failed')
    expect { Legion::Data::Connection.setup }.to raise_error(Sequel::Error, /configuration failed/)
    expect(Legion::Data.connected?).to be(false)
    expect(Legion::Data.connection).to be_nil
    expect(@databases.last.pool.size).to eq(0)
  end

  it 'closes the shared connection when local initialization fails' do
    Legion::Settings[:data][:local][:enabled] = true
    allow(Legion::Data::Local).to receive(:setup).and_raise(Sequel::DatabaseError, 'local migration failed')
    expect { Legion::Data.setup }.to raise_error(Sequel::DatabaseError, /local migration failed/)
    expect(Legion::Data.connected?).to be(false)
    expect(Legion::Data.connection).to be_nil
    expect(@databases.last.pool.size).to eq(0)
  end
end
