# frozen_string_literal: true

require 'spec_helper'
require 'legion/data/connection'

RSpec.describe Legion::Data::Connection do
  describe '#merge_tls_creds' do
    let(:base_creds) { { host: '127.0.0.1', port: 5432, user: 'legion', password: 'secret' } }

    before do
      stub_const('Legion::Crypt::TLS', Module.new do
        def self.resolve(config, **)
          if config[:enabled]
            { enabled: true, verify: :peer, ca: '/etc/ssl/ca.pem', cert: nil, key: nil }
          else
            { enabled: false }
          end
        end
      end)
    end

    context 'when adapter is sqlite' do
      it 'returns creds unchanged' do
        result = described_class.merge_tls_creds(base_creds, adapter: :sqlite, port: nil)
        expect(result).to eq(base_creds)
      end
    end

    context 'when data.tls.enabled is false (default)' do
      before do
        allow(Legion::Settings).to receive(:[]).with(:data).and_return(
          { tls: { enabled: false } }
        )
      end

      it 'returns creds unchanged for postgres' do
        result = described_class.merge_tls_creds(base_creds.dup, adapter: :postgres, port: 5432)
        expect(result[:sslmode]).to be_nil
      end

      it 'returns creds unchanged for mysql2' do
        result = described_class.merge_tls_creds(base_creds.dup, adapter: :mysql2, port: 3306)
        expect(result[:ssl_mode]).to be_nil
      end
    end

    context 'when data.tls.enabled is true for postgres' do
      before do
        allow(Legion::Settings).to receive(:[]).with(:data).and_return(
          { tls: { enabled: true, verify: 'peer' } }
        )
      end

      it 'sets sslmode to verify-full' do
        result = described_class.merge_tls_creds(base_creds.dup, adapter: :postgres, port: 5432)
        expect(result[:sslmode]).to eq('verify-full')
      end

      it 'sets sslrootcert when ca is present' do
        result = described_class.merge_tls_creds(base_creds.dup, adapter: :postgres, port: 5432)
        expect(result[:sslrootcert]).to eq('/etc/ssl/ca.pem')
      end
    end

    context 'when data.tls.enabled is true with verify none for postgres' do
      before do
        allow(Legion::Settings).to receive(:[]).with(:data).and_return(
          { tls: { enabled: true, verify: 'none' } }
        )

        stub_const('Legion::Crypt::TLS', Module.new do
          def self.resolve(_config, **)
            { enabled: true, verify: :none, ca: nil, cert: nil, key: nil }
          end
        end)
      end

      it 'sets sslmode to require (not verify-full)' do
        result = described_class.merge_tls_creds(base_creds.dup, adapter: :postgres, port: 5432)
        expect(result[:sslmode]).to eq('require')
      end
    end

    context 'when data.tls.enabled is true for mysql2' do
      before do
        allow(Legion::Settings).to receive(:[]).with(:data).and_return(
          { tls: { enabled: true, verify: 'peer' } }
        )
      end

      it 'sets ssl_mode to verify_identity' do
        result = described_class.merge_tls_creds(base_creds.dup, adapter: :mysql2, port: 3306)
        expect(result[:ssl_mode]).to eq('verify_identity')
      end
    end

    context 'when Crypt::TLS is not defined' do
      before do
        hide_const('Legion::Crypt::TLS')
        allow(Legion::Settings).to receive(:[]).with(:data).and_return(
          { tls: { enabled: true } }
        )
      end

      it 'returns creds unchanged' do
        result = described_class.merge_tls_creds(base_creds.dup, adapter: :postgres, port: 5432)
        expect(result[:sslmode]).to be_nil
      end
    end
  end
end
