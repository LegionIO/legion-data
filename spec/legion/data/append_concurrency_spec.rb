# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'legion/data/audit_record'
require 'legion/data/event_store'

RSpec.describe 'Concurrent database appends' do
  around do |example|
    Dir.mktmpdir('legion-appends') do |directory|
      options = { max_connections: 4, timeout: 10_000 }
      options[:after_connect] = proc do |connection|
        Legion::Data::Connection.configure_sqlite_busy_handler(connection: connection, timeout: options[:timeout])
      end
      @database = Sequel.sqlite(File.join(directory, 'appends.db'), **options)
      Sequel::Migrator.run(@database, File.expand_path('../../../lib/legion/data/migrations', __dir__))
      example.run
    ensure
      @database&.disconnect
    end
  end

  before { allow(Legion::Data).to receive(:connection).and_return(@database) }

  it 'preserves every accepted audit record and governance event without forks or sequence conflicts' do
    start = Queue.new
    workers = []
    begin
      4.times do |writer|
        workers << Thread.new do
          start.pop
          4.times do |index|
            token = "#{writer}-#{index}"
            Legion::Data::AuditRecord.append(chain_id: 'concurrent', content_type: 'test',
                                             content_hash: Digest::SHA256.hexdigest(token))
            Legion::Data::EventStore.append(stream: 'concurrent', type: 'test', data: { token: token })
          end
        end
      end
      workers.size.times { start << true }
      workers.each(&:value)

      tokens = (0...4).flat_map { |writer| (0...4).map { |index| "#{writer}-#{index}" } }
      records = Legion::Data::AuditRecord.walk(chain_id: 'concurrent')
      events = Legion::Data::EventStore.read_stream('concurrent')
      expect(Legion::Data::AuditRecord.verify(chain_id: 'concurrent')).to eq(valid: true, length: 16)
      expect(Legion::Data::EventStore.verify_chain('concurrent')).to eq(valid: true, length: 16)
      expect(records.map { |record| record[:content_hash] }.sort).to eq(tokens.map { |token| Digest::SHA256.hexdigest(token) }.sort)
      expect(events.map { |event| event[:data][:token] }.sort).to eq(tokens.sort)
      expect(events.map { |event| event[:sequence] }).to eq((1..16).to_a)
    ensure
      workers.size.times { start << true }
      workers.each(&:join)
    end
  end
end
