# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Data do
  around do |example|
    original = Legion::Data::Connection.sequel
    settings = Legion::Settings[:data].dup
    begin
      Legion::Data::Connection.sequel = nil
      Legion::Settings[:data][:connected] = false
      example.run
    ensure
      Legion::Data::Connection.shutdown
      Legion::Data::Connection.sequel = original
      Legion::Settings[:data].replace(settings)
      Legion::Data::Models.load
    end
  end

  it 'has a version number' do
    expect(Legion::Data::VERSION).to be_a String
  end

  it 'can init' do
    expect { Legion::Data.setup }.not_to raise_exception
    expect(Legion::Settings[:data][:connected]).to eq true
  end

  describe '.shutdown' do
    it 'should update Legion::Settings connection status' do
      Legion::Data::Connection.setup
      Legion::Data.shutdown
      expect(Legion::Settings[:data][:connected]).to eq false
    end
  end

  it '.setup_cache' do
    expect(Legion::Settings[:data][:cache][:connected]).to eq false
    expect(Legion::Data.setup_cache).to eq nil
    expect(Legion::Settings[:data][:cache][:connected]).to eq false
  end
end
