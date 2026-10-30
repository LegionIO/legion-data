# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Data::Models do
  after(:each) do
    Legion::Settings[:data][:models][:autoload] = true
    Legion::Settings[:data][:models][:continue_on_load_fail] = false
  end

  it 'can load' do
    expect { Legion::Data::Models.load }.not_to raise_error
    expect(Legion::Settings[:data][:models][:loaded]).to eq true
  end

  it '.require_sequel_models' do
    expect(Legion::Data::Models.require_sequel_models).to be_a Array
    expect(Legion::Data::Models.require_sequel_models([])).to eq []
    expect { Legion::Data::Models.require_sequel_models(['bad_model']) }.to raise_error(LoadError)
  end

  it '.load_sequel_model' do
    expect(Legion::Data::Models.load_sequel_model('task')).to eq 'task'
    expect { Legion::Data::Models.load_sequel_model('bad_model') }.to raise_error(LoadError)
  end

  describe 'settings-driven behaviour' do
    it 'respects autoload: false by skipping model loading' do
      Legion::Settings[:data][:models][:autoload] = false
      result = Legion::Data.load_models
      expect(result).to be_nil
    end

    it 'uses continue_on_load_fail to swallow LoadError' do
      Legion::Settings[:data][:models][:continue_on_load_fail] = true
      expect { Legion::Data::Models.load_sequel_model('does_not_exist') }.not_to raise_error
    end

    it 'raises LoadError when continue_on_load_fail is false' do
      Legion::Settings[:data][:models][:continue_on_load_fail] = false
      expect { Legion::Data::Models.load_sequel_model('does_not_exist') }.to raise_error(LoadError)
    end
  end

  it '.models' do
    expect(Legion::Data::Models.models).to be_a Array
    expect(Legion::Data::Models.models).to include 'task'
    expect(Legion::Data::Models.models).to include 'runner'
    expect(Legion::Data::Models.models).to include 'extension'
    expect(Legion::Data::Models.models).to include 'node'
    expect(Legion::Data::Models.models).to include 'setting'
    expect(Legion::Data::Models.models).to include 'function'
    expect(Legion::Data::Models.models).not_to include 'bad_model'
  end
end
