# frozen_string_literal: true

require 'spec_helper'
require 'legion/data/encryption/key_provider'
require 'legion/data/encryption/cipher'

RSpec.describe Legion::Data::Encryption::KeyProvider do
  let(:provider) { described_class.new }

  it 'provides an AES-256 key without Crypt' do
    hide_const('Legion::Crypt')
    expect(provider.key_for.bytesize).to eq(32)
  end

  context 'with separate default and tenant keys' do
    let(:default_key) { 'd' * 32 }
    let(:tenant_key) { 't' * 32 }

    before do
      stub_const('Legion::Crypt', Module.new)
      stub_const('Legion::Crypt::PartitionKeys', Module.new)
      allow(Legion::Crypt).to receive(:default_encryption_key).and_return(default_key)
      allow(Legion::Crypt::PartitionKeys).to receive(:derive).with(tenant_id: '__default__').and_return(tenant_key)
    end

    it 'prevents cross-scope decryption in either cache population order' do
      [nil, '__default__'].each do |first_tenant|
        keys = described_class.new
        keys.key_for(tenant_id: first_tenant)
        tenant_blob = Legion::Data::Encryption::Cipher.encrypt('tenant secret', key: keys.key_for(tenant_id: '__default__'))

        expect(Legion::Data::Encryption::Cipher.decrypt(tenant_blob, key: tenant_key)).to eq('tenant secret')
        expect(keys.key_for).to eq(default_key)
        expect do
          Legion::Data::Encryption::Cipher.decrypt(tenant_blob, key: keys.key_for)
        end.to raise_error(OpenSSL::Cipher::CipherError)
      end
    end

    it 'keeps cached keys stable until clearing, then refreshes both scopes' do
      provider.key_for
      provider.key_for(tenant_id: '__default__')
      allow(Legion::Crypt).to receive(:default_encryption_key).and_return('n' * 32)
      allow(Legion::Crypt::PartitionKeys).to receive(:derive).with(tenant_id: '__default__').and_return('r' * 32)

      expect(provider.key_for).to eq(default_key)
      expect(provider.key_for(tenant_id: '__default__')).to eq(tenant_key)
      provider.clear_cache!
      expect(provider.key_for).to eq('n' * 32)
      expect(provider.key_for(tenant_id: '__default__')).to eq('r' * 32)
    end
  end
end
