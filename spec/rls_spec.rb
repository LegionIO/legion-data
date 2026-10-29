# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Data::Rls do
  it 'preserves block results and errors when PostgreSQL isolation is unavailable' do
    allow(described_class).to receive(:rls_enabled?).and_return(false)
    expect(described_class.with_tenant('tenant') { 42 }).to eq(42)
    expect { described_class.with_tenant('tenant') { raise 'work failed' } }.to raise_error('work failed')
  end

  context 'with pooled PostgreSQL sessions' do
    before do
      @database = Sequel.mock(host: :postgres, max_connections: 2, preconnect: true)
      allow(Legion::Data).to receive(:connection).and_return(@database)
      allow(described_class).to receive(:rls_enabled?).and_return(true)
      # Simulate PostgreSQL session variables at the adapter boundary; keep the real pool.
      @database.define_singleton_method(:_execute) do |connection, sql, options = Sequel::OPTS, &block|
        case sql
        when /\ASET app.current_tenant = '(.*)'\z/
          connection.instance_variable_set(:@tenant, Regexp.last_match(1))
        when 'RESET app.current_tenant'
          connection.instance_variable_set(:@tenant, nil)
        when 'SHOW app.current_tenant'
          block.call(current_tenant: connection.instance_variable_get(:@tenant))
        else
          super(connection, sql, options, &block)
        end
      end
    end

    after do
      @database.disconnect
    end

    it 'keeps concurrent tenant scopes isolated and clears sessions before reuse' do
      entered = Queue.new
      release = Queue.new
      workers = %w[tenant-a tenant-b].map do |tenant|
        Thread.new do
          described_class.with_tenant(tenant) do
            entered << true
            release.pop
            [tenant, described_class.current_tenant]
          end
        end
      end
      2.times { entered.pop }
      2.times { release << true }
      expect(workers.map(&:value).sort).to eq([%w[tenant-a tenant-a], %w[tenant-b tenant-b]])
      expect(Array.new(2) { described_class.current_tenant }).to eq([nil, nil])
    ensure
      2.times { release << true }
      workers&.each(&:join)
    end

    it 'restores an outer tenant after a nested scope raises' do
      described_class.with_tenant('outer') do
        expect do
          described_class.with_tenant('inner') do
            expect(described_class.current_tenant).to eq('inner')
            raise 'work failed'
          end
        end.to raise_error('work failed')
        expect(described_class.current_tenant).to eq('outer')
      end
      expect(Array.new(2) { described_class.current_tenant }).to eq([nil, nil])
    end
  end
end
