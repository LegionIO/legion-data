# frozen_string_literal: true

require 'spec_helper'
Legion::Data::Connection.setup
Legion::Data::Models.load

RSpec.describe Legion::Data::Model::Setting do
  it { should be_a Sequel::Model }
end
