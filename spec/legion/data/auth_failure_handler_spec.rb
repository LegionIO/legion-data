# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Data::AuthFailureHandler do
  after { described_class.reset! }

  describe '.auth_failure?' do
    it 'matches role does not exist' do
      error = StandardError.new('FATAL: role "v-legionio-node-abc123" does not exist')
      expect(described_class.auth_failure?(error)).to be true
    end

    it 'matches password authentication failed' do
      error = StandardError.new('FATAL: password authentication failed for user "v-legionio-node-abc123"')
      expect(described_class.auth_failure?(error)).to be true
    end

    it 'matches no pg_hba.conf entry' do
      error = StandardError.new('FATAL: no pg_hba.conf entry for host "10.0.0.1"')
      expect(described_class.auth_failure?(error)).to be true
    end

    it 'does not match unrelated errors' do
      error = StandardError.new('PG::ConnectionBad: could not connect to server: Connection refused')
      expect(described_class.auth_failure?(error)).to be false
    end

    it 'does not match permission denied (not an auth failure)' do
      error = StandardError.new('ERROR: permission denied for table schedules')
      expect(described_class.auth_failure?(error)).to be false
    end
  end

  describe '.on_cooldown?' do
    it 'returns false when no reissue has been requested' do
      expect(described_class.on_cooldown?).to be false
    end

    it 'returns true immediately after a reissue request' do
      error = StandardError.new('FATAL: role "dead-role" does not exist')
      described_class.request_reissue(error)
      expect(described_class.on_cooldown?).to be true
    end
  end

  describe '.handle' do
    it 'calls request_reissue for auth failures' do
      error = StandardError.new('FATAL: role "v-legionio-node-xyz" does not exist')
      expect(described_class).to receive(:request_reissue).with(error)
      described_class.handle(error)
    end

    it 'does nothing for non-auth errors' do
      error = StandardError.new('connection refused')
      expect(described_class).not_to receive(:request_reissue)
      described_class.handle(error)
    end

    it 'does nothing when on cooldown' do
      error = StandardError.new('FATAL: role "v-legionio-node-xyz" does not exist')
      described_class.request_reissue(error)
      expect(described_class).not_to receive(:request_reissue)
      described_class.handle(error)
    end
  end

  describe '.install' do
    it 'prepends ConnectHook on the sequel database singleton class' do
      mock_db = Sequel.sqlite
      described_class.install(mock_db)
      expect(mock_db.singleton_class.ancestors).to include(described_class::ConnectHook)
      mock_db.disconnect
    end
  end

  describe '.reset!' do
    it 'clears cooldown state' do
      error = StandardError.new('FATAL: role "dead" does not exist')
      described_class.request_reissue(error)
      expect(described_class.on_cooldown?).to be true
      described_class.reset!
      expect(described_class.on_cooldown?).to be false
    end
  end
end
