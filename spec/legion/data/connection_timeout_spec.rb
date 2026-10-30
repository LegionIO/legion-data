# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'PostgreSQL session timeout initialization' do
  around do |example|
    settings = Legion::Settings[:data]
    original_settings = settings.dup
    original_connection = Legion::Data::Connection.sequel
    original_adapter = Legion::Data::Connection.instance_variable_get(:@adapter)
    begin
      settings.merge!(adapter: 'postgres', statement_timeout: 37, lock_timeout: 19,
                      log: false, query_log: false, dev_mode: false, test: true,
                      preconnect: false, read_replica_url: nil, replicas: [])
      example.run
    ensure
      @database&.disconnect
      settings.replace(original_settings)
      Legion::Data::Connection.sequel = original_connection
      Legion::Data::Connection.instance_variable_set(:@adapter, original_adapter)
    end
  end

  before do
    allow(Sequel).to receive(:connect).and_wrap_original do |connect, options|
      connect.call(options.merge(adapter: :mock, host: :postgres))
    end
  end

  def setup_database
    Legion::Data::Connection.setup
    @database = Legion::Data::Connection.sequel
  end

  it 'configures the initial and all preconnected sessions before use' do
    Legion::Settings[:data].merge!(preconnect: true, max_connections: 2)
    setup_database
    expect(@database.sqls).to eq([
                                   "SET statement_timeout = '37ms'", "SET lock_timeout = '19ms'",
                                   "SET statement_timeout = '37ms'", "SET lock_timeout = '19ms'"
                                 ])
  end

  it 'configures replacement sessions after a disconnect' do
    setup_database
    @database.sqls
    @database.disconnect
    @database.test_connection
    expect(@database.sqls).to eq(["SET statement_timeout = '37ms'", "SET lock_timeout = '19ms'"])
  end

  it 'leaves unset timeouts alone and honors an explicit zero timeout' do
    Legion::Settings[:data].merge!(statement_timeout: nil, lock_timeout: 0)
    setup_database
    expect(@database.sqls).to eq(["SET lock_timeout = '0ms'"])
  end
end
