# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

RSpec.describe 'SQLite lock contention' do
  around do |example|
    settings = Legion::Settings[:data]
    original_settings = settings.slice(:adapter, :timeout, :log, :query_log)
    original_adapter = Legion::Data::Connection.instance_variable_get(:@adapter)
    settings.merge!(adapter: 'sqlite', timeout: 1000, log: false, query_log: false)
    Legion::Data::Connection.instance_variable_set(:@adapter, :sqlite)
    Dir.mktmpdir('legion-sqlite-contention') do |dir|
      @path = File.join(dir, 'contention.db')
      example.run
    ensure
      @database&.disconnect
    end
  ensure
    settings.merge!(original_settings)
    Legion::Data::Connection.instance_variable_set(:@adapter, original_adapter)
  end

  def connect_database
    options = Legion::Data::Connection.send(:sequel_opts)
    @database = Sequel.sqlite(@path, **options)
    @database.create_table(:items) { primary_key :id }
  end

  it 'lets the lock holder commit while another Ruby thread waits to write' do
    connect_database
    locked = Queue.new
    writer_started = Queue.new
    holder = Thread.new do
      @database.transaction(mode: :immediate) do
        @database[:items].insert
        locked << true
        writer_started.pop
        sleep 0.05
      end
    end
    locked.pop
    writer_started << true
    @database[:items].insert
    holder.value
    expect(@database[:items].count).to eq(2)
  ensure
    holder&.join
  end

  it 'raises a busy error when the configured wait expires' do
    Legion::Settings[:data][:timeout] = 25
    connect_database
    locked = Queue.new
    release = Queue.new
    holder = Thread.new do
      @database.transaction(mode: :immediate) do
        @database[:items].insert
        locked << true
        release.pop
      end
    end
    locked.pop
    expect { @database[:items].insert }.to raise_error(Sequel::DatabaseError, /locked/)
  ensure
    release << true
    holder&.value
  end
end
