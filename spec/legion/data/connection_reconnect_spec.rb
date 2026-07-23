# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Legion::Data::Connection.reconnect_with_fresh_creds' do
  before(:each) do
    @saved_creds = Legion::Settings[:data][:creds]&.dup
  end

  after(:each) do
    Legion::Data::Connection.shutdown
    Legion::Settings[:data][:creds] = @saved_creds
  end

  context 'when adapter is sqlite' do
    let(:mock_sequel) { instance_double(Sequel::SQLite::Database, opts: {}) }

    it 'returns false (no-op for sqlite)' do
      Legion::Data::Connection.instance_variable_set(:@sequel, mock_sequel)
      Legion::Data::Connection.instance_variable_set(:@adapter, :sqlite)
      expect(Legion::Data::Connection.reconnect_with_fresh_creds).to be false
    end

    after do
      Legion::Data::Connection.instance_variable_set(:@adapter, nil)
      Legion::Data::Connection.instance_variable_set(:@sequel, nil)
    end
  end

  context 'when sequel is nil' do
    it 'returns false' do
      Legion::Data::Connection.instance_variable_set(:@sequel, nil)
      expect(Legion::Data::Connection.reconnect_with_fresh_creds).to be false
    end
  end

  context 'with a postgres adapter (mocked)' do
    let(:mock_pool) { double('pool') }
    let(:mock_sequel) do
      instance_double(Sequel::Database, opts: { user: 'old-vault-user', password: 'old-pass' }, pool: mock_pool)
    end

    before do
      Legion::Data::Connection.instance_variable_set(:@sequel, mock_sequel)
      Legion::Data::Connection.instance_variable_set(:@adapter, :postgres)
    end

    after do
      Legion::Data::Connection.instance_variable_set(:@adapter, nil)
      Legion::Data::Connection.instance_variable_set(:@sequel, nil)
    end

    it 'updates sequel opts and reconnects with fresh creds' do
      Legion::Settings[:data][:creds] = { user: 'new-vault-user', password: 'new-pass', host: '127.0.0.1', port: 5432 }

      allow(mock_sequel).to receive(:disconnect)
      allow(mock_sequel).to receive(:test_connection).and_return(true)

      result = Legion::Data::Connection.reconnect_with_fresh_creds

      expect(result).to be true
      expect(mock_sequel.opts[:user]).to eq('new-vault-user')
      expect(mock_sequel.opts[:password]).to eq('new-pass')
      expect(mock_sequel).to have_received(:disconnect)
      expect(mock_sequel).to have_received(:test_connection)
    end

    it 'handles :username key as fallback' do
      Legion::Settings[:data][:creds] = { username: 'alt-user', password: 'alt-pass' }

      allow(mock_sequel).to receive(:disconnect)
      allow(mock_sequel).to receive(:test_connection).and_return(true)

      result = Legion::Data::Connection.reconnect_with_fresh_creds

      expect(result).to be true
      expect(mock_sequel.opts[:user]).to eq('alt-user')
    end

    it 'returns false when creds lack user/password' do
      Legion::Settings[:data][:creds] = { host: '127.0.0.1' }

      expect(Legion::Data::Connection.reconnect_with_fresh_creds).to be false
    end

    it 'returns false when creds is not a hash' do
      Legion::Settings[:data][:creds] = nil

      expect(Legion::Data::Connection.reconnect_with_fresh_creds).to be false
    end

    it 'returns false and handles exception when test_connection fails' do
      Legion::Settings[:data][:creds] = { user: 'new-user', password: 'new-pass' }

      allow(mock_sequel).to receive(:disconnect)
      allow(mock_sequel).to receive(:test_connection).and_raise(Sequel::DatabaseConnectionError.new('connection refused'))

      result = Legion::Data::Connection.reconnect_with_fresh_creds

      expect(result).to be false
    end
  end
end
