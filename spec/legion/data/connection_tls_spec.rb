# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Legion::Data::Connection TLS' do
  around do |example|
    original = Legion::Settings[:data][:tls]
    begin
      Legion::Settings[:data][:tls] = { enabled: false }
      example.run
    ensure
      Legion::Settings[:data][:tls] = original
    end
  end

  before do
    stub_const('Legion::Crypt::TLS', Module.new)
  end

  describe '.merge_tls_creds' do
    context 'with postgres adapter and TLS enabled' do
      before do
        Legion::Settings[:data][:tls] = { enabled: true }
      end

      it 'adds sslmode and sslrootcert' do
        allow(Legion::Crypt::TLS).to receive(:resolve).and_return(
          { enabled: true, verify: :peer, ca: '/ca.crt', cert: nil, key: nil, auto_detected: false }
        )
        creds = {}
        result = Legion::Data::Connection.merge_tls_creds(creds, adapter: :postgres, port: 5432)
        expect(result[:sslmode]).to eq 'verify-full'
        expect(result[:sslrootcert]).to eq '/ca.crt'
      end

      it 'uses sslmode require for verify none' do
        allow(Legion::Crypt::TLS).to receive(:resolve).and_return(
          { enabled: true, verify: :none, ca: nil, cert: nil, key: nil, auto_detected: false }
        )
        creds = {}
        result = Legion::Data::Connection.merge_tls_creds(creds, adapter: :postgres, port: 5432)
        expect(result[:sslmode]).to eq 'require'
      end

      it 'includes sslcert and sslkey for mutual TLS' do
        allow(Legion::Crypt::TLS).to receive(:resolve).and_return(
          { enabled: true, verify: :mutual, ca: '/ca.crt', cert: '/c.crt', key: '/c.key', auto_detected: false }
        )
        creds = {}
        result = Legion::Data::Connection.merge_tls_creds(creds, adapter: :postgres, port: 5432)
        expect(result[:sslcert]).to eq '/c.crt'
        expect(result[:sslkey]).to eq '/c.key'
      end
    end

    context 'with mysql2 adapter and TLS enabled' do
      before do
        Legion::Settings[:data][:tls] = { enabled: true }
      end

      it 'adds ssl_mode and sslca' do
        allow(Legion::Crypt::TLS).to receive(:resolve).and_return(
          { enabled: true, verify: :peer, ca: '/ca.crt', cert: nil, key: nil, auto_detected: false }
        )
        creds = {}
        result = Legion::Data::Connection.merge_tls_creds(creds, adapter: :mysql2, port: 3306)
        expect(result[:ssl_mode]).to eq 'verify_identity'
        expect(result[:sslca]).to eq '/ca.crt'
      end

      it 'uses ssl_mode required for verify none' do
        allow(Legion::Crypt::TLS).to receive(:resolve).and_return(
          { enabled: true, verify: :none, ca: nil, cert: nil, key: nil, auto_detected: false }
        )
        creds = {}
        result = Legion::Data::Connection.merge_tls_creds(creds, adapter: :mysql2, port: 3306)
        expect(result[:ssl_mode]).to eq 'required'
      end
    end

    context 'when TLS is disabled' do
      it 'returns creds unchanged' do
        expect(Legion::Crypt::TLS).not_to receive(:resolve)
        creds = { host: 'db.example.com' }
        result = Legion::Data::Connection.merge_tls_creds(creds, adapter: :postgres, port: 5432)
        expect(result).to eq({ host: 'db.example.com' })
      end
    end

    it 'honors disabling TLS in the live tree after an enabled connection configuration' do
      Legion::Settings[:data][:tls] = { enabled: true, verify: 'peer' }
      allow(Legion::Crypt::TLS).to receive(:resolve).and_return({ enabled: true, verify: :peer })
      secure = Legion::Data::Connection.merge_tls_creds({}, adapter: :postgres, port: 5432)
      expect(secure[:sslmode]).to eq('verify-full')

      Legion::Settings[:data][:tls] = { enabled: false }
      expect(Legion::Crypt::TLS).not_to receive(:resolve)
      disabled = Legion::Data::Connection.merge_tls_creds({ host: 'db.example.com' }, adapter: :postgres, port: 5432)
      expect(disabled).to eq(host: 'db.example.com')
    end

    context 'when sqlite adapter' do
      it 'skips TLS entirely' do
        creds = { database: 'test.db' }
        result = Legion::Data::Connection.merge_tls_creds(creds, adapter: :sqlite, port: nil)
        expect(result).to eq({ database: 'test.db' })
      end
    end

    context 'when Legion::Crypt::TLS is not defined' do
      it 'returns creds unchanged' do
        hide_const('Legion::Crypt::TLS')
        creds = { host: 'db.example.com' }
        result = Legion::Data::Connection.merge_tls_creds(creds, adapter: :postgres, port: 5432)
        expect(result).to eq({ host: 'db.example.com' })
      end
    end
  end
end
