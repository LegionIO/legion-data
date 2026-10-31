# frozen_string_literal: true

require 'spec_helper'
require 'stringio'

RSpec.describe 'Database pool shutdown' do
  around do |example|
    original = Legion::Data::Connection.sequel
    settings = Legion::Settings[:data].dup
    logger = Legion::Data::Connection.instance_variable_get(:@query_file_logger)
    begin
      Legion::Data::Connection.instance_variable_set(:@query_file_logger, nil)
      example.run
    ensure
      @database&.disconnect
      Legion::Data::Connection.sequel = original
      Legion::Data::Connection.instance_variable_set(:@query_file_logger, logger)
      Legion::Settings[:data].replace(settings)
    end
  end

  it 'closes an idle timed queue immediately instead of waiting for the drain timeout' do
    @database = Sequel.sqlite(pool_class: :timed_queue)
    Legion::Data::Connection.sequel = @database
    Legion::Settings[:data][:shutdown_timeout] = 5
    raw = @database.synchronize { |connection| connection }
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    expect(Legion::Data::Connection.shutdown).to be(true)
    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 1
    expect(raw).to be_closed
  end

  %i[timed_queue threaded sharded_timed_queue sharded_threaded].each do |pool_class|
    it "drains #{pool_class} without closing active work or accepting new work" do
      options = { pool_class: pool_class }
      sharded = pool_class.to_s.start_with?('sharded')
      options[:servers] = { reader: {} } if sharded
      server = sharded ? :reader : :default
      @database = Sequel.sqlite(**options)
      Legion::Data::Connection.sequel = @database
      Legion::Settings[:data][:connected] = true
      Legion::Settings[:data][:shutdown_timeout] = 0
      logger_io = StringIO.new
      logger = Logger.new(logger_io)
      Legion::Data::Connection.instance_variable_set(:@query_file_logger, logger)
      entered = Queue.new
      release = Queue.new
      worker = nil
      begin
        worker = Thread.new do
          @database.synchronize(server) do |connection|
            entered << connection
            release.pop
            @database.dataset.server(server).get(42)
          end
        end
        raw = entered.pop

        expect(Legion::Data.shutdown).to be(false)
        expect(Legion::Data.connected?).to be(true)
        expect(raw).not_to be_closed
        expect { @database.get(1) }.to raise_error(Sequel::Error)
        expect(@database.pool.shutdown_status).to eq(state: :draining, active_requests: 1)
        expect(logger_io).not_to be_closed

        release << true
        expect(worker.value).to eq(42)
        expect(raw).to be_closed
        expect { @database.get(1) }.to raise_error(Sequel::Error)
        expect(Legion::Data.connected?).to be(false)
        expect(@database.pool.shutdown_status).to eq(state: :closed, active_requests: 0)
        expect(logger_io).to be_closed
      ensure
        release << true
        worker&.join
      end
    end
  end

  it 'does not deadlock when the current lease requests shutdown' do
    @database = Sequel.sqlite
    Legion::Data::Connection.sequel = @database
    Legion::Settings[:data][:shutdown_timeout] = 5
    @database.synchronize do |connection|
      expect(Legion::Data::Connection.shutdown).to be(false)
      expect(connection.execute('SELECT 1')).to eq([[1]])
    end
    expect(@database.pool.shutdown_status).to eq(state: :closed, active_requests: 0)
  end
end
