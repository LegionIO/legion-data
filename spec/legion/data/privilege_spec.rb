# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Legion::Data privilege checks' do
  around do |example|
    original = Legion::Data::Connection.sequel
    settings = Legion::Settings[:data].dup
    @databases = []
    Legion::Settings[:data].merge!(connected: true, adapter: 'postgres')
    begin
      example.run
    ensure
      @databases.each(&:disconnect)
      Legion::Data::Connection.sequel = original
      Legion::Settings[:data].replace(settings)
    end
  end

  def use_database(database)
    @databases << database
    Legion::Data::Connection.sequel = database
    database
  end

  it 'does not grant access while disconnected' do
    use_database(Sequel.sqlite)
    Legion::Settings[:data][:connected] = false

    expect(Legion::Data.can_read?(:tasks)).to be false
    expect(Legion::Data.can_write?(:tasks)).to be false
  end

  it 'recognizes usable SQLite after falling back from configured PostgreSQL' do
    database = use_database(Sequel.sqlite)
    database.create_table(:tasks) { String :value }

    expect(Legion::Data.can_read?(:tasks)).to be true
    expect(Legion::Data.can_write?(:tasks)).to be true
    database[:tasks].insert(value: 'fallback')
    expect(database[:tasks].select_map(:value)).to eq(['fallback'])
  end

  it 'does not bypass active PostgreSQL permissions when settings say SQLite' do
    use_database(Sequel.mock(host: 'postgres', fetch: [{ can: false }]))
    Legion::Settings[:data][:adapter] = 'sqlite'

    expect(Legion::Data.can_read?(:tasks)).to be false
    expect(Legion::Data.can_write?(:tasks)).to be false
  end

  it 'retries permission lookups after a transient query failure' do
    unavailable = true
    use_database(Sequel.mock(host: 'postgres', fetch: lambda do |_sql|
      raise Sequel::DatabaseError, 'connection temporarily unavailable' if unavailable

      [{ can: true }]
    end))

    expect(Legion::Data.can_read?(:tasks)).to be false
    expect(Legion::Data.can_write?(:tasks)).to be false
    unavailable = false
    expect(Legion::Data.can_read?(:tasks)).to be true
    expect(Legion::Data.can_write?(:tasks)).to be true
  end

  it 'refreshes successful cached denials when explicitly reset' do
    granted = false
    use_database(Sequel.mock(host: 'postgres', fetch: ->(_sql) { [{ can: granted }] }))

    expect(Legion::Data.can_read?(:tasks)).to be false
    expect(Legion::Data.can_write?(:tasks)).to be false
    granted = true
    expect(Legion::Data.can_read?(:tasks)).to be false
    expect(Legion::Data.can_write?(:tasks)).to be false
    Legion::Data.reset_privileges!
    expect(Legion::Data.can_read?(:tasks)).to be true
    expect(Legion::Data.can_write?(:tasks)).to be true
  end

  it 'does not reuse permissions from a replaced physical pool connection' do
    granted = true
    database = use_database(Sequel.mock(host: 'postgres', fetch: ->(_sql) { [{ can: granted }] }))

    expect(Legion::Data.can_read?(:tasks)).to be true
    expect(Legion::Data.can_write?(:tasks)).to be true
    granted = false
    database.disconnect
    expect(Legion::Data.can_read?(:tasks)).to be false
    expect(Legion::Data.can_write?(:tasks)).to be false
  end

  it 'cannot repopulate replacement permissions from an in-flight old connection' do
    release = nil
    previous_lookup = nil
    entered = Queue.new
    release = Queue.new
    use_database(Sequel.mock(host: 'postgres', fetch: lambda do |_sql|
      entered << true
      release.pop
      [{ can: true }]
    end))
    previous_lookup = Thread.new { Legion::Data.can_read?(:tasks) }
    entered.pop

    use_database(Sequel.mock(host: 'postgres', fetch: [{ can: false }]))
    expect(Legion::Data.can_read?(:tasks)).to be false
    release << true
    expect(previous_lookup.value).to be true
    expect(Legion::Data.can_read?(:tasks)).to be false
  ensure
    release << true if release
    previous_lookup&.join
  end

  describe '.connected?' do
    it 'returns true when data is connected' do
      expect(Legion::Data.connected?).to be true
    end

    it 'returns false when data is not connected' do
      Legion::Settings[:data][:connected] = false
      expect(Legion::Data.connected?).to be false
    end

    it 'returns false on error' do
      allow(Legion::Settings).to receive(:[]).and_call_original
      allow(Legion::Settings).to receive(:[]).with(:data).and_raise(StandardError)
      expect(Legion::Data.connected?).to be false
    end
  end
end
