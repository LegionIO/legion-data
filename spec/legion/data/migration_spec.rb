# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Data::Migration do
  it 'can migrate' do
    expect { Legion::Data::Migration.migrate }.not_to raise_exception
    expect(Legion::Settings[:data][:migrations][:version]).to be_a Integer
    expect(Legion::Settings[:data][:migrations][:ran]).to eq true
  end
end
