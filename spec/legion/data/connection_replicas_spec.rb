# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Data::Connection do
  # Save and restore all touched state around each example
  before(:each) do
    @saved_adapter       = Legion::Settings[:data][:adapter]
    @saved_replica_url   = Legion::Settings[:data][:read_replica_url]
    @saved_replicas      = Legion::Settings[:data][:replicas]
    @saved_connected     = Legion::Settings[:data][:connected]
    @saved_ivar_adapter  = described_class.instance_variable_get(:@adapter)
    @saved_ivar_sequel   = described_class.instance_variable_get(:@sequel)
    @saved_ivar_replicas = described_class.instance_variable_get(:@replica_servers)

    # Reset mutable state before each example
    described_class.instance_variable_set(:@adapter, nil)
    described_class.instance_variable_set(:@replica_servers, nil)
    Legion::Settings[:data][:connected] = false
  end

  after(:each) do
    described_class.instance_variable_set(:@adapter, @saved_ivar_adapter)
    described_class.instance_variable_set(:@sequel, @saved_ivar_sequel)
    described_class.instance_variable_set(:@replica_servers, @saved_ivar_replicas)
    Legion::Settings[:data][:adapter]          = @saved_adapter
    Legion::Settings[:data][:read_replica_url] = @saved_replica_url
    Legion::Settings[:data][:replicas]         = @saved_replicas
    Legion::Settings[:data][:connected]        = @saved_connected
  end

  # Build a minimal Sequel::Database double with the methods we call.
  def fake_sequel_db(**)
    db = instance_double(Sequel::Database)
    allow(db).to receive(:extension)
    allow(db).to receive(:add_servers)
    allow(db).to receive(:disconnect)
    allow(db).to receive(:loggers).and_return([])
    allow(db).to receive(:logger=)
    allow(db).to receive(:sql_log_level=)
    allow(db).to receive(:log_warn_duration=)
    db
  end

  describe '#connect_with_replicas' do
    context 'when adapter is sqlite' do
      it 'is a no-op and does not call extension' do
        Legion::Settings[:data][:adapter]          = 'sqlite'
        Legion::Settings[:data][:read_replica_url] = 'postgres://replica/db'
        Legion::Settings[:data][:replicas]         = []

        db = fake_sequel_db
        described_class.instance_variable_set(:@sequel, db)
        described_class.instance_variable_set(:@adapter, :sqlite)

        expect(db).not_to receive(:extension)
        expect(db).not_to receive(:add_servers)

        described_class.connect_with_replicas
        expect(described_class.replica_servers).to be_empty
      end
    end

    context 'when adapter is postgres but no replicas configured' do
      it 'is a no-op when both read_replica_url and replicas are empty' do
        Legion::Settings[:data][:read_replica_url] = nil
        Legion::Settings[:data][:replicas]         = []

        db = fake_sequel_db
        described_class.instance_variable_set(:@sequel, db)
        described_class.instance_variable_set(:@adapter, :postgres)

        expect(db).not_to receive(:extension)
        expect(db).not_to receive(:add_servers)

        described_class.connect_with_replicas
        expect(described_class.replica_servers).to be_empty
      end

      it 'is a no-op when read_replica_url is empty string and replicas is empty' do
        Legion::Settings[:data][:read_replica_url] = ''
        Legion::Settings[:data][:replicas]         = []

        db = fake_sequel_db
        described_class.instance_variable_set(:@sequel, db)
        described_class.instance_variable_set(:@adapter, :postgres)

        expect(db).not_to receive(:extension)
        described_class.connect_with_replicas
        expect(described_class.replica_servers).to be_empty
      end
    end

    context 'when adapter is postgres with a single read_replica_url' do
      it 'loads server_block extension and adds :read_0 server' do
        url = 'postgres://replica-host/db'
        Legion::Settings[:data][:read_replica_url] = url
        Legion::Settings[:data][:replicas]         = []

        db = fake_sequel_db
        described_class.instance_variable_set(:@sequel, db)
        described_class.instance_variable_set(:@adapter, :postgres)

        expect(db).to receive(:extension).with(:server_block)
        expect(db).to receive(:add_servers).with(read_0: url)

        described_class.connect_with_replicas
        expect(described_class.replica_servers).to eq([:read_0])
      end
    end

    context 'when adapter is postgres with multiple replicas in the array' do
      it 'adds :read_0 and :read_1 servers' do
        url0 = 'postgres://replica-0/db'
        url1 = 'postgres://replica-1/db'
        Legion::Settings[:data][:read_replica_url] = nil
        Legion::Settings[:data][:replicas]         = [url0, url1]

        db = fake_sequel_db
        described_class.instance_variable_set(:@sequel, db)
        described_class.instance_variable_set(:@adapter, :postgres)

        expect(db).to receive(:extension).with(:server_block)
        expect(db).to receive(:add_servers).with(read_0: url0)
        expect(db).to receive(:add_servers).with(read_1: url1)

        described_class.connect_with_replicas
        expect(described_class.replica_servers).to eq(%i[read_0 read_1])
      end
    end

    context 'deduplication when read_replica_url is also in replicas array' do
      it 'registers the URL only once as :read_0' do
        url = 'postgres://replica/db'
        Legion::Settings[:data][:read_replica_url] = url
        Legion::Settings[:data][:replicas]         = [url]

        db = fake_sequel_db
        described_class.instance_variable_set(:@sequel, db)
        described_class.instance_variable_set(:@adapter, :postgres)

        expect(db).to receive(:extension).with(:server_block)
        expect(db).to receive(:add_servers).with(read_0: url).once

        described_class.connect_with_replicas
        expect(described_class.replica_servers).to eq([:read_0])
      end
    end

    context 'server_block extension loading' do
      it 'calls @sequel.extension(:server_block) when replicas are present' do
        url = 'postgres://replica/db'
        Legion::Settings[:data][:read_replica_url] = url
        Legion::Settings[:data][:replicas]         = []

        db = fake_sequel_db
        described_class.instance_variable_set(:@sequel, db)
        described_class.instance_variable_set(:@adapter, :postgres)

        expect(db).to receive(:extension).with(:server_block)
        described_class.connect_with_replicas
      end
    end
  end

  describe '#read_server' do
    it 'returns :read_0 when replicas are configured' do
      described_class.instance_variable_set(:@replica_servers, [:read_0])
      expect(described_class.read_server).to eq(:read_0)
    end

    it 'returns :default when no replicas are configured' do
      described_class.instance_variable_set(:@replica_servers, nil)
      expect(described_class.read_server).to eq(:default)
    end

    it 'returns :default when replica_servers is an empty array' do
      described_class.instance_variable_set(:@replica_servers, [])
      expect(described_class.read_server).to eq(:default)
    end
  end

  describe '#replica_servers' do
    it 'returns empty array before any replica wiring' do
      described_class.instance_variable_set(:@replica_servers, nil)
      expect(described_class.replica_servers).to eq([])
    end

    it 'returns the registered server names after wiring' do
      url0 = 'postgres://r0/db'
      url1 = 'postgres://r1/db'
      Legion::Settings[:data][:read_replica_url] = nil
      Legion::Settings[:data][:replicas]         = [url0, url1]

      db = fake_sequel_db
      described_class.instance_variable_set(:@sequel, db)
      described_class.instance_variable_set(:@adapter, :postgres)

      described_class.connect_with_replicas
      expect(described_class.replica_servers).to eq(%i[read_0 read_1])
    end
  end

  describe 'settings flag to disable replicas' do
    it 'does not wire replicas when replicas array is empty and read_replica_url is nil' do
      Legion::Settings[:data][:read_replica_url] = nil
      Legion::Settings[:data][:replicas]         = []

      db = fake_sequel_db
      described_class.instance_variable_set(:@sequel, db)
      described_class.instance_variable_set(:@adapter, :postgres)

      described_class.connect_with_replicas

      expect(described_class.replica_servers).to be_empty
      expect(described_class.read_server).to eq(:default)
    end
  end
end
