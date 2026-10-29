# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Data::Connection do
  around do |example|
    settings = Legion::Settings[:data]
    original_settings = settings.dup
    original_state = %i[@sequel @adapter @replica_servers @fallback_active].to_h do |name|
      [name, described_class.instance_variable_get(name)]
    end
    settings.merge!(adapter: 'postgres', creds: { user: 'primary', password: 'primary-password', database: 'ledger' },
                    read_replica_url: nil, replicas: [], log: false, query_log: false, test: true,
                    preconnect: false, dev_mode: false, shutdown_timeout: 0, statement_timeout: 37, lock_timeout: 19)
    @databases = []
    example.run
  ensure
    @databases.each(&:disconnect)
    settings.replace(original_settings)
    original_state.each { |name, value| described_class.instance_variable_set(name, value) }
  end

  before do
    allow(Sequel).to receive(:connect).and_wrap_original do |connect, options|
      connect.call(options.merge(adapter: :mock, host: :postgres))
    end
  end

  def setup_database
    described_class.setup
    @databases << described_class.sequel
    described_class.sequel
  end

  it 'opens distinct replica sessions using decoded URLs and inherited timeouts' do
    first = 'postgres://replica%2Buser:p%40ss@replica-one:5434/ledger?sslmode=verify-full'
    Legion::Settings[:data].merge!(read_replica_url: first, replicas: [nil, first, 'postgres://replica-two/ledger'])
    database = setup_database

    expect(described_class.replica_servers).to eq(%i[read_0 read_1])
    database.synchronize(described_class.read_server) do |connection|
      expect(connection.opts.slice(:host, :port, :user, :password, :sslmode)).to eq(
        host: 'replica-one', port: 5434, user: 'replica+user', password: 'p@ss', sslmode: 'verify-full'
      )
    end
    database.synchronize(:read_1) do |connection|
      expect(connection.opts.slice(:host, :user, :password)).to eq(
        host: 'replica-two', user: 'primary', password: 'primary-password'
      )
    end
    expect(database.sqls).to include("SET statement_timeout = '37ms' -- read_0", "SET lock_timeout = '19ms' -- read_1")
  end

  it 'routes explicit replica queries through the sharded pool' do
    Legion::Settings[:data][:read_replica_url] = 'postgres://replica/ledger'
    database = setup_database
    database[:items].server(described_class.read_server).all
    expect(database.sqls).to include('SELECT * FROM "items" -- read_0')
  end

  it 'clears replica routing on shutdown and reconfiguration without replicas' do
    Legion::Settings[:data][:read_replica_url] = 'postgres://replica/ledger'
    setup_database
    described_class.shutdown
    expect(described_class.read_server).to eq(:default)

    Legion::Settings[:data][:read_replica_url] = nil
    database = setup_database
    expect(described_class.replica_servers).to eq([])
    expect(database.sharded?).to be(false)
    database[:items].server(described_class.read_server).all
    expect(database.sqls).to include('SELECT * FROM "items"')
  end

  it 'rejects non-PostgreSQL replica URLs before connection creation' do
    Legion::Settings[:data][:read_replica_url] = 'mysql2://replica/ledger'
    expect { setup_database }.to raise_error(ArgumentError, /PostgreSQL URLs/)
  end
end
