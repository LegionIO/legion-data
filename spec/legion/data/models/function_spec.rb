# frozen_string_literal: true

require 'spec_helper'
Legion::Data::Connection.setup
Legion::Data::Models.load

RSpec.describe Legion::Data::Model::Function do
  it { should respond_to? :runner }
  it { should respond_to? :trigger_relationships }
  it { should respond_to? :action_relationships }
  it { should respond_to? :user_owner }
  it { should respond_to? :group_owner }
  it { should be_a Sequel::Model }
end
