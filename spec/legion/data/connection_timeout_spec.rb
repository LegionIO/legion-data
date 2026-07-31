# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Legion::Data::Connection timeout discipline' do
  after(:each) do
    Legion::Data::Connection.shutdown
  end

  describe 'settings defaults' do
    it 'statement_timeout defaults to 5000ms' do
      expect(Legion::Data::Settings.default[:statement_timeout]).to eq(5000)
    end

    it 'lock_timeout defaults to 2000ms' do
      expect(Legion::Data::Settings.default[:lock_timeout]).to eq(2000)
    end

    it 'keepalives defaults to 1 (enabled)' do
      expect(Legion::Data::Settings.default[:keepalives]).to eq(1)
    end

    it 'keepalives_idle defaults to 10s' do
      expect(Legion::Data::Settings.default[:keepalives_idle]).to eq(10)
    end

    it 'keepalives_interval defaults to 5s' do
      expect(Legion::Data::Settings.default[:keepalives_interval]).to eq(5)
    end

    it 'keepalives_count defaults to 3' do
      expect(Legion::Data::Settings.default[:keepalives_count]).to eq(3)
    end

    it 'tcp_user_timeout defaults to 15000ms' do
      expect(Legion::Data::Settings.default[:tcp_user_timeout]).to eq(15_000)
    end

    it 'shutdown_timeout defaults to 5s' do
      expect(Legion::Data::Settings.default[:shutdown_timeout]).to eq(5)
    end
  end

  describe 'ADAPTER_KEYS[:postgres]' do
    it 'includes TCP keepalive params' do
      keys = Legion::Data::Connection::ADAPTER_KEYS[:postgres]
      expect(keys).to include(:keepalives)
      expect(keys).to include(:keepalives_idle)
      expect(keys).to include(:keepalives_interval)
      expect(keys).to include(:keepalives_count)
      expect(keys).to include(:tcp_user_timeout)
    end

    it 'includes connect_timeout' do
      expect(Legion::Data::Connection::ADAPTER_KEYS[:postgres]).to include(:connect_timeout)
    end
  end

  describe 'ADAPTER_DEFAULTS[:postgres]' do
    it 'has a 5s connect_timeout' do
      expect(Legion::Data::Connection::ADAPTER_DEFAULTS[:postgres][:connect_timeout]).to eq(5)
    end

    it 'wires keepalive defaults' do
      defaults = Legion::Data::Connection::ADAPTER_DEFAULTS[:postgres]
      expect(defaults[:keepalives]).to eq(1)
      expect(defaults[:keepalives_idle]).to eq(10)
      expect(defaults[:keepalives_interval]).to eq(5)
      expect(defaults[:keepalives_count]).to eq(3)
      expect(defaults[:tcp_user_timeout]).to eq(15_000)
    end
  end

  describe 'ADAPTER_DEFAULTS[:mysql2]' do
    it 'has 5s connect/read/write timeouts' do
      defaults = Legion::Data::Connection::ADAPTER_DEFAULTS[:mysql2]
      expect(defaults[:connect_timeout]).to eq(5)
      expect(defaults[:read_timeout]).to eq(5)
      expect(defaults[:write_timeout]).to eq(5)
    end
  end

  describe 'sequel_opts for sqlite' do
    it 'passes through ADAPTER_KEYS[:sqlite] options' do
      Legion::Data::Connection.setup
      opts = Legion::Data::Connection.sequel.opts
      expect(opts[:timeout]).to eq(5000)
    end
  end

  describe 'shutdown with force_disconnect_pool' do
    it 'disconnects cleanly when no connections are checked out' do
      Legion::Data::Connection.setup
      expect { Legion::Data::Connection.shutdown }.not_to raise_error
      expect(Legion::Settings[:data][:connected]).to eq(false)
    end

    it 'respects shutdown_timeout setting' do
      expect(Legion::Settings[:data][:shutdown_timeout]).to eq(5)
    end
  end
end
