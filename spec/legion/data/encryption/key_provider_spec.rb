# frozen_string_literal: true

require 'spec_helper'
require 'legion/data/encryption/key_provider'
require 'legion/data/encryption/cipher'
require 'json'
require 'open3'
require 'rbconfig'
require 'tmpdir'

RSpec.describe Legion::Data::Encryption::KeyProvider do
  let(:provider) { described_class.new }

  it 'provides an AES-256 key without Crypt' do
    hide_const('Legion::Crypt')
    expect(provider.key_for.bytesize).to eq(32)
  end

  it 'persists default-scope encrypted columns across processes with real Crypt and rejects an invalid key' do
    script = <<~'RUBY'
      require 'bundler/setup'
      require 'json'
      require 'legion/logging'
      Legion::Logging.setup(log_file: File::NULL, level: 'fatal')
      require 'legion/settings'
      Legion::Settings.load
      require 'legion/crypt'
      require 'legion/crypt/partition_keys'
      require 'legion/data'
      require 'legion/data/encryption/sequel_plugin'

      secret = 'a' * (Legion::Settings[:crypt][:cluster_length] * 2)
      Legion::Crypt.set_cluster_secret(secret, false)
      db = Sequel.sqlite(ARGV.fetch(0))
      begin
        Sequel::Migrator.run(db, File.expand_path('lib/legion/data/migrations'), target: 3)
        db.alter_table(:settings) { set_column_type :value, :blob } if ARGV.fetch(1) == 'write'
        Sequel::Model.db = db
        require 'legion/data/models/setting'
        model = Legion::Data::Model::Setting
        model.plugin(Legion::Data::Encryption::SequelPlugin)
        model.encrypted_column(:value)
        record = if ARGV.fetch(1) == 'write'
                   model.create(key: 'key-provider-regression', value: 'persisted secret')
                 else
                   model[key: 'key-provider-regression']
                 end
        raise 'persisted Setting is missing' unless record

        stored = model[record.id]
        value = stored.value
        raw = stored.values.fetch(:value)
        aad = Legion::Data::Encryption::SequelPlugin.aad_for(table_name: :settings, primary_key: record.id, column: :value)
        decrypted = Legion::Data::Encryption::Cipher.decrypt(raw.b, key: Legion::Crypt.cs, aad: aad)
        raise 'stored value does not use the real Crypt key' unless decrypted == value

        model.encryption_key_provider.clear_cache!
        Legion::Settings[:crypt][:cluster_secret] = 'invalid'
        rejected = begin
          model.encryption_key_provider.key_for
          false
        rescue Legion::Crypt::ClusterSecret::InitializationError => error
          warn "Expected key initialization rejection: #{error.class}"
          true
        end
        puts JSON.generate(value: value, stored_plaintext: raw == value, invalid_key_rejected: rejected)
      ensure
        db.disconnect
      end
    RUBY
    root = File.expand_path('../../../..', __dir__)
    Dir.mktmpdir('legion-key-provider') do |directory|
      database = File.join(directory, 'encrypted-settings.db')
      %w[write read].each do |operation|
        stdout, stderr, status = Open3.capture3(RbConfig.ruby, '-Ilib', '-e', script, database, operation, chdir: root)
        expect(status.exitstatus).to eq(0), "#{stdout}\n#{stderr}"
        expect(JSON.parse(stdout.lines.last, symbolize_names: true)).to eq(
          value: 'persisted secret', stored_plaintext: false, invalid_key_rejected: true
        )
      end
    end
  end

  context 'when caching independently supplied scope keys' do
    let(:default_key) { 'd' * 32 }
    let(:tenant_key) { 't' * 32 }

    before do
      allow(provider).to receive(:derive_key).with(nil).and_return(default_key)
      allow(provider).to receive(:derive_key).with('__default__').and_return(tenant_key)
    end

    it 'prevents cross-scope decryption in either cache population order' do
      [nil, '__default__'].each do |first_tenant|
        keys = provider
        keys.clear_cache!
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
      allow(provider).to receive(:derive_key).with(nil).and_return('n' * 32)
      allow(provider).to receive(:derive_key).with('__default__').and_return('r' * 32)

      expect(provider.key_for).to eq(default_key)
      expect(provider.key_for(tenant_id: '__default__')).to eq(tenant_key)
      provider.clear_cache!
      expect(provider.key_for).to eq('n' * 32)
      expect(provider.key_for(tenant_id: '__default__')).to eq('r' * 32)
    end
  end
end
