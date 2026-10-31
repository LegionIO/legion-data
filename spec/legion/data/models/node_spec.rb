# frozen_string_literal: true

require 'spec_helper'
Legion::Data::Connection.setup
Legion::Data::Models.load

RSpec.describe Legion::Data::Model::Node do
  it { should respond_to? :environment }
  it { should respond_to? :dataceter }
  it { should respond_to? :task_log }
  it { should be_a Sequel::Model }

  describe '#parsed_metrics' do
    it 'returns deserialized hash when metrics is valid JSON' do
      node = described_class.new(metrics: Legion::JSON.dump({ memory_rss_mb: 142 }))
      expect(node.parsed_metrics).to be_a(Hash)
      expect(node.parsed_metrics[:memory_rss_mb]).to eq(142)
    end

    it 'returns nil when metrics is nil' do
      node = described_class.new(metrics: nil)
      expect(node.parsed_metrics).to be_nil
    end

    it 'returns nil when metrics is invalid JSON' do
      node = described_class.new(metrics: 'not-json{{{')
      expect(node.parsed_metrics).to be_nil
    end
  end

  describe '#parsed_hosted_worker_ids' do
    it 'returns deserialized array when hosted_worker_ids is valid JSON' do
      node = described_class.new(hosted_worker_ids: Legion::JSON.dump(%w[w1 w2]))
      expect(node.parsed_hosted_worker_ids).to eq(%w[w1 w2])
    end

    it 'returns empty array when hosted_worker_ids is nil' do
      node = described_class.new(hosted_worker_ids: nil)
      expect(node.parsed_hosted_worker_ids).to eq([])
    end

    it 'returns empty array when hosted_worker_ids is invalid JSON' do
      node = described_class.new(hosted_worker_ids: 'bad-json')
      expect(node.parsed_hosted_worker_ids).to eq([])
    end
  end
end
