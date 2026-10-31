# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'

# Stub extension modules for testing
module Legion
  module Extensions
    module LLM
      module Gateway; end
    end

    module Metering; end
    module Audit; end
  end

  module LLM; end
end

RSpec.describe Legion::Data::Spool do
  let(:tmpdir) { Dir.mktmpdir('legion_spool_spec') }

  before do
    described_class.root = tmpdir
  end

  after do
    described_class.instance_variable_set(:@root, nil)
    FileUtils.rm_rf(tmpdir)
  end

  describe '.root' do
    it 'returns the configured root' do
      expect(described_class.root).to eq(tmpdir)
    end

    it 'defaults to ~/.legionio/data/spool when not set' do
      described_class.instance_variable_set(:@root, nil)
      expect(described_class.root).to eq(File.expand_path('~/.legionio/data/spool'))
    end
  end

  describe '.for' do
    it 'returns a ScopedSpool' do
      spool = described_class.for(Legion::Extensions::Metering)
      expect(spool).to be_a(Legion::Data::Spool::ScopedSpool)
    end

    it 'rejects modules not under the Legion namespace' do
      expect { described_class.for(String) }.to raise_error(ArgumentError, /not under the Legion:: namespace/)
    end

    it 'accepts core gem modules under Legion::' do
      spool = described_class.for(Legion::LLM)
      spool.write(:metering, { test: true })
      expect(Dir.exist?(File.join(tmpdir, 'llm/metering'))).to be true
    end

    it 'derives path from module name' do
      spool = described_class.for(Legion::Extensions::LLM::Gateway)
      spool.write(:metering, { test: true })
      expect(Dir.exist?(File.join(tmpdir, 'llm/gateway/metering'))).to be true
    end

    it 'derives path for single-level extensions' do
      spool = described_class.for(Legion::Extensions::Metering)
      spool.write(:events, { test: true })
      expect(Dir.exist?(File.join(tmpdir, 'metering/events'))).to be true
    end
  end
end

RSpec.describe Legion::Data::Spool::ScopedSpool do
  let(:tmpdir) { Dir.mktmpdir('legion_spool_spec') }
  let(:spool) { Legion::Data::Spool::ScopedSpool.new(Legion::Extensions::LLM::Gateway, tmpdir) }
  let(:sub_ns) { :metering }
  let(:subdir) { File.join(tmpdir, 'llm/gateway/metering') }
  let(:quarantine_dir) { File.join(subdir, 'quarantine') }

  after do
    FileUtils.rm_rf(tmpdir)
  end

  describe '#write' do
    it 'creates the sub-namespace directory if it does not exist' do
      spool.write(sub_ns, foo: 'bar')
      expect(Dir.exist?(File.join(tmpdir, 'llm/gateway/metering'))).to be true
    end

    it 'creates a JSON file in the scoped directory' do
      spool.write(sub_ns, foo: 'bar')
      files = Dir[File.join(tmpdir, 'llm/gateway/metering', '*.json')]
      expect(files.size).to eq(1)
    end

    it 'returns the file path' do
      path = spool.write(sub_ns, foo: 'bar')
      expect(File.exist?(path)).to be true
    end

    it 'writes valid JSON content' do
      spool.write(sub_ns, key: 'value')
      files = Dir[File.join(tmpdir, 'llm/gateway/metering', '*.json')]
      content = JSON.parse(File.read(files.first), symbolize_names: true)
      expect(content).to eq({ key: 'value' })
    end

    it 'does not leave temporary files behind' do
      spool.write(sub_ns, key: 'value')

      expect(Dir[File.join(subdir, '.*.tmp-*')]).to be_empty
    end

    it 'names files with timestamp-uuid pattern' do
      path = spool.write(sub_ns, x: 1)
      filename = File.basename(path, '.json')
      expect(filename).to match(/\A\d{10,}-[0-9a-f-]{36}\z/)
    end

    it 'isolates from other extensions' do
      other_spool = Legion::Data::Spool::ScopedSpool.new(Legion::Extensions::Audit, tmpdir)
      spool.write(sub_ns, from: 'gateway')
      other_spool.write(sub_ns, from: 'audit')
      expect(spool.count(sub_ns)).to eq(1)
      expect(other_spool.count(sub_ns)).to eq(1)
    end
  end

  describe '#read' do
    it 'returns an empty array for a missing sub-namespace' do
      expect(spool.read(:nonexistent)).to eq([])
    end

    it 'returns parsed hashes with symbol keys' do
      spool.write(sub_ns, foo: 'bar')
      events = spool.read(sub_ns)
      expect(events.first).to include(foo: 'bar')
    end

    it 'returns events in FIFO order' do
      spool.write(sub_ns, order: 1)
      sleep 0.01
      spool.write(sub_ns, order: 2)
      sleep 0.01
      spool.write(sub_ns, order: 3)
      events = spool.read(sub_ns)
      expect(events.map { |e| e[:order] }).to eq([1, 2, 3])
    end

    it 'sorts files by filename before reading' do
      FileUtils.mkdir_p(subdir)
      File.binwrite(File.join(subdir, '200.json'), JSON.generate(order: 2))
      File.binwrite(File.join(subdir, '100.json'), JSON.generate(order: 1))
      File.binwrite(File.join(subdir, '300.json'), JSON.generate(order: 3))

      events = spool.read(sub_ns)

      expect(events.map { |e| e[:order] }).to eq([1, 2, 3])
    end

    it 'quarantines corrupt files and continues reading valid ones' do
      FileUtils.mkdir_p(subdir)
      File.binwrite(File.join(subdir, '100.json'), JSON.generate(order: 1))
      File.binwrite(File.join(subdir, '200.json'), '{"order":')
      File.binwrite(File.join(subdir, '300.json'), JSON.generate(order: 2))

      events = spool.read(sub_ns)

      expect(events.map { |e| e[:order] }).to eq([1, 2])
      expect(Dir[File.join(quarantine_dir, '*.corrupt')].size).to eq(1)
      expect(spool.count(sub_ns)).to eq(2)
    end

    it 'does not delete files' do
      spool.write(sub_ns, x: 1)
      spool.read(sub_ns)
      expect(spool.count(sub_ns)).to eq(1)
    end
  end

  describe '#flush' do
    it 'yields each event' do
      spool.write(sub_ns, a: 1)
      spool.write(sub_ns, a: 2)
      yielded = []
      spool.flush(sub_ns) { |e| yielded << e }
      expect(yielded.size).to eq(2)
    end

    it 'deletes files after successful block execution' do
      spool.write(sub_ns, a: 1)
      spool.flush(sub_ns) { |_e| nil }
      expect(spool.count(sub_ns)).to eq(0)
    end

    it 'preserves callback errors and leaves the event available for retry' do
      spool.write(sub_ns, a: 1)
      expect do
        spool.flush(sub_ns) { |_event| raise Errno::ENOENT, 'callback dependency missing' }
      end.to raise_error(Errno::ENOENT)

      expect(spool.read(sub_ns)).to eq([{ a: 1 }])
      replayed = []
      expect(spool.flush(sub_ns) { |event| replayed << event }).to eq(1)
      expect(replayed).to eq([{ a: 1 }])
    end

    it 'returns the number of successfully processed events' do
      spool.write(sub_ns, a: 1)
      spool.write(sub_ns, a: 2)
      result = spool.flush(sub_ns) { |_e| nil }
      expect(result).to eq(2)
    end

    it 'processes events in FIFO order' do
      spool.write(sub_ns, order: 1)
      sleep 0.01
      spool.write(sub_ns, order: 2)
      seen = []
      spool.flush(sub_ns) { |e| seen << e[:order] }
      expect(seen).to eq([1, 2])
    end

    it 'quarantines corrupt files and continues draining valid ones' do
      FileUtils.mkdir_p(subdir)
      File.binwrite(File.join(subdir, '100.json'), JSON.generate(order: 1))
      File.binwrite(File.join(subdir, '200.json'), '{"order":')
      File.binwrite(File.join(subdir, '300.json'), JSON.generate(order: 2))

      seen = []
      result = spool.flush(sub_ns) { |e| seen << e[:order] }

      expect(seen).to eq([1, 2])
      expect(result).to eq(2)
      expect(spool.count(sub_ns)).to eq(0)
      expect(Dir[File.join(quarantine_dir, '*.corrupt')].size).to eq(1)
    end

    it 'prevents another instance from replaying or clearing an in-flight event' do
      spool.write(sub_ns, a: 1)
      other = described_class.new(Legion::Extensions::LLM::Gateway, tmpdir)
      entered = Queue.new
      release = Queue.new
      worker = nil
      begin
        worker = Thread.new do
          spool.flush(sub_ns) do |event|
            entered << event
            release.pop
          end
        end
        expect(entered.pop).to eq(a: 1)
        duplicate = []
        expect(other.flush(sub_ns) { |event| duplicate << event }).to eq(0)
        expect(duplicate).to be_empty
        expect(other.read(sub_ns)).to be_empty
        other.clear(sub_ns)
        expect(other.count(sub_ns)).to eq(1)

        release << true
        expect(worker.value).to eq(1)
        expect(other.count(sub_ns)).to eq(0)
      ensure
        release << true
        worker&.join
      end
    end

    it 'recovers an abruptly exited owner with at-least-once delivery' do
      spool.write(sub_ns, a: 1)
      effects = File.join(tmpdir, 'effects.log')
      pid = Process.fork do
        spool.flush(sub_ns) do |event|
          File.write(effects, "#{event[:a]}\n", mode: 'a')
          Process.exit!(42)
        end
        Process.exit!(43)
      end
      status = Process.wait2(pid).last
      expect(status.exitstatus).to eq(42)
      expect(spool.count(sub_ns)).to eq(1)

      other = described_class.new(Legion::Extensions::LLM::Gateway, tmpdir)
      expect(other.flush(sub_ns) { |event| File.write(effects, "#{event[:a]}\n", mode: 'a') }).to eq(1)
      expect(File.readlines(effects)).to eq(%W[1\n 1\n])
      expect(other.count(sub_ns)).to eq(0)
    end
  end

  describe '#count' do
    it 'returns 0 for a missing sub-namespace' do
      expect(spool.count(:nonexistent)).to eq(0)
    end

    it 'returns the number of pending JSON files' do
      spool.write(sub_ns, a: 1)
      spool.write(sub_ns, a: 2)
      expect(spool.count(sub_ns)).to eq(2)
    end

    it 'decrements after flush' do
      spool.write(sub_ns, a: 1)
      spool.write(sub_ns, a: 2)
      spool.flush(sub_ns) { |_e| nil }
      expect(spool.count(sub_ns)).to eq(0)
    end
  end

  describe '#clear' do
    it 'removes all JSON files in the sub-namespace' do
      spool.write(sub_ns, a: 1)
      spool.write(sub_ns, a: 2)
      spool.clear(sub_ns)
      expect(spool.count(sub_ns)).to eq(0)
    end

    it 'does not raise for missing sub-namespace' do
      expect { spool.clear(:nonexistent) }.not_to raise_error
    end

    it 'leaves the directory in place after clearing' do
      spool.write(sub_ns, a: 1)
      spool.clear(sub_ns)
      expect(Dir.exist?(File.join(tmpdir, 'llm/gateway/metering'))).to be true
    end
  end
end
