# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Migration 116: make llm_tool_calls.message_inference_response_id nullable' do
  let(:db) { Legion::Data::Connection.sequel }

  def index_names(table)
    if db.adapter_scheme == :postgres
      db.indexes(table).keys.map(&:to_s)
    else
      db[:sqlite_master].where(type: 'index', tbl_name: table.to_s).select_map(:name)
    end
  end

  before(:all) do
    migration_path = File.expand_path('../../../../lib/legion/data/migrations', __dir__)
    Sequel::Migrator.run(Legion::Data::Connection.sequel, migration_path, target: 116)
  end

  it 'makes message_inference_response_id nullable' do
    column = db.schema(:llm_tool_calls).to_h[:message_inference_response_id]
    expect(column[:allow_null]).to be true
  end

  it 'preserves idx_tool_calls_identity_principal_id after column change' do
    expect(index_names(:llm_tool_calls)).to include('idx_tool_calls_identity_principal_id')
  end
end
