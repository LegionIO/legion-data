# frozen_string_literal: true

require 'spec_helper'
require 'legion/data/archival'

RSpec.describe Legion::Data::Archival do
  let(:db) { Sequel.sqlite }
  let(:old) { Time.utc(2020, 1, 2) }

  before do
    Legion::Data::Migration.migrate(db)
    allow(Legion::Data).to receive(:connection).and_return(db)
  end

  after do
    db.disconnect
  end

  it 'archives completed and failed tasks through the scheduled entry point' do
    ids = %w[completed failed].map { |status| db[:tasks].insert(status: status, created: old) }
    result = described_class.run_scheduled_archival
    expect(result[:tasks][:archived]).to eq(2)
    expect(db[:tasks].count).to eq(0)
    expect(db[:tasks_archive].select_map(:original_id)).to contain_exactly(*ids)
  end

  it 'respects the batch bound without moving recent or active tasks' do
    recent = db[:tasks].insert(status: 'completed', created: Time.now)
    active = db[:tasks].insert(status: 'running', created: old)
    eligible = Array.new(3) { db[:tasks].insert(status: 'completed', created: old) }

    expect(described_class.archive_completed_tasks(batch_size: 2)[:archived]).to eq(2)
    expect(db[:tasks].select_map(:id)).to contain_exactly(recent, active, eligible.last)
    expect(db[:tasks_archive].select_map(:original_id)).to eq(eligible.first(2))
  end

  it 'does not delete tasks when the archive table is unavailable' do
    id = db[:tasks].insert(status: 'completed', created: old)
    db.drop_table(:tasks_archive)
    expect(described_class.archive_completed_tasks[:archived]).to eq(0)
    expect(db[:tasks][id: id][:status]).to eq('completed')
  end
end
