# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Data::Helper do
  describe '#data_connected?' do
    let(:test_class) do
      Class.new do
        include Legion::Data::Helper
      end
    end
    let(:instance) { test_class.new }

    it 'returns true when data is connected' do
      allow(Legion::Settings).to receive(:[]).with(:data).and_return({ connected: true })
      expect(instance.data_connected?).to be true
    end

    it 'returns false when data is not connected' do
      allow(Legion::Settings).to receive(:[]).with(:data).and_return({ connected: false })
      expect(instance.data_connected?).to be false
    end
  end

  describe '#data_connection' do
    let(:test_class) do
      Class.new do
        include Legion::Data::Helper
      end
    end
    let(:instance) { test_class.new }

    it 'delegates to Legion::Data::Connection.sequel' do
      expect(instance.data_connection).to eq(Legion::Data::Connection.sequel)
    end
  end

  describe '#data_path' do
    let(:test_class) do
      Class.new do
        include Legion::Data::Helper

        def full_path
          '/opt/legion/extensions/lex-test'
        end
      end
    end
    let(:instance) { test_class.new }

    it 'returns the data subdirectory path' do
      expect(instance.data_path).to eq('/opt/legion/extensions/lex-test/data')
    end

    it 'memoizes the result' do
      first = instance.data_path
      expect(instance.data_path).to equal(first)
    end
  end

  describe '#local_data_connected?' do
    let(:test_class) do
      Class.new do
        include Legion::Data::Helper
      end
    end
    let(:instance) { test_class.new }

    it 'delegates to Legion::Data::Local.connected?' do
      allow(Legion::Data::Local).to receive(:connected?).and_return(true)
      expect(instance.local_data_connected?).to be true
    end
  end

  describe '#local_data_connection' do
    let(:test_class) do
      Class.new do
        include Legion::Data::Helper
      end
    end
    let(:instance) { test_class.new }

    it 'delegates to Legion::Data::Local.connection' do
      conn = double('local_connection')
      allow(Legion::Data::Local).to receive(:connection).and_return(conn)
      expect(instance.local_data_connection).to eq(conn)
    end
  end

  describe '#local_data_model' do
    let(:test_class) do
      Class.new do
        include Legion::Data::Helper
      end
    end
    let(:instance) { test_class.new }

    it 'delegates to Legion::Data::Local.model with table name' do
      model = double('model')
      allow(Legion::Data::Local).to receive(:model).with(:tasks).and_return(model)
      expect(instance.local_data_model(:tasks)).to eq(model)
    end
  end

  describe '#data_adapter' do
    let(:test_class) do
      Class.new do
        include Legion::Data::Helper
      end
    end
    let(:instance) { test_class.new }

    it 'delegates to Legion::Data::Connection.adapter' do
      allow(Legion::Data::Connection).to receive(:adapter).and_return(:sqlite)
      expect(instance.data_adapter).to eq(:sqlite)
    end

    it 'returns :unknown when an error is raised' do
      allow(Legion::Data::Connection).to receive(:adapter).and_raise(StandardError)
      expect(instance.data_adapter).to eq(:unknown)
    end
  end

  describe '#data_pool_stats' do
    let(:test_class) do
      Class.new do
        include Legion::Data::Helper
      end
    end
    let(:instance) { test_class.new }

    it 'returns {} when not connected' do
      allow(Legion::Settings).to receive(:[]).with(:data).and_return({ connected: false })
      expect(instance.data_pool_stats).to eq({})
    end

    it 'delegates to Legion::Data::Connection.pool_stats when connected' do
      stats = { size: 5, available: 3, in_use: 2 }
      allow(Legion::Settings).to receive(:[]).with(:data).and_return({ connected: true })
      allow(Legion::Data::Connection).to receive(:pool_stats).and_return(stats)
      expect(instance.data_pool_stats).to eq(stats)
    end

    it 'returns {} when an error is raised' do
      allow(Legion::Settings).to receive(:[]).and_return({})
      allow(Legion::Settings).to receive(:[]).with(:data).and_return({ connected: true })
      allow(Legion::Data::Connection).to receive(:pool_stats).and_raise(StandardError)
      expect(instance.data_pool_stats).to eq({})
    end
  end

  describe '#data_stats' do
    let(:test_class) do
      Class.new do
        include Legion::Data::Helper
      end
    end
    let(:instance) { test_class.new }

    it 'returns {} when not connected' do
      allow(Legion::Settings).to receive(:[]).with(:data).and_return({ connected: false })
      expect(instance.data_stats).to eq({})
    end

    it 'delegates to Legion::Data.stats when connected' do
      stats = { shared: { adapter: 'sqlite' }, local: {} }
      allow(Legion::Settings).to receive(:[]).with(:data).and_return({ connected: true })
      allow(Legion::Data).to receive(:stats).and_return(stats)
      expect(instance.data_stats).to eq(stats)
    end

    it 'returns {} when an error is raised' do
      allow(Legion::Settings).to receive(:[]).and_return({})
      allow(Legion::Settings).to receive(:[]).with(:data).and_return({ connected: true })
      allow(Legion::Data).to receive(:stats).and_raise(StandardError)
      expect(instance.data_stats).to eq({})
    end
  end

  describe '#local_data_stats' do
    let(:test_class) do
      Class.new do
        include Legion::Data::Helper
      end
    end
    let(:instance) { test_class.new }

    it 'returns {} when local is not connected' do
      allow(Legion::Data::Local).to receive(:connected?).and_return(false)
      expect(instance.local_data_stats).to eq({})
    end

    it 'delegates to Legion::Data::Local.stats when connected' do
      stats = { tables: 3, size_bytes: 4096 }
      allow(Legion::Data::Local).to receive(:connected?).and_return(true)
      allow(Legion::Data::Local).to receive(:stats).and_return(stats)
      expect(instance.local_data_stats).to eq(stats)
    end

    it 'returns {} when an error is raised' do
      allow(Legion::Data::Local).to receive(:connected?).and_return(true)
      allow(Legion::Data::Local).to receive(:stats).and_raise(StandardError)
      expect(instance.local_data_stats).to eq({})
    end
  end

  describe '#data_can_read?' do
    let(:test_class) do
      Class.new do
        include Legion::Data::Helper
      end
    end
    let(:instance) { test_class.new }

    it 'returns false when an error is raised' do
      allow(Legion::Data).to receive(:can_read?).and_raise(StandardError)
      expect(instance.data_can_read?(:tasks)).to be false
    end
  end

  describe '#data_can_write?' do
    let(:test_class) do
      Class.new do
        include Legion::Data::Helper
      end
    end
    let(:instance) { test_class.new }

    it 'returns false when an error is raised' do
      allow(Legion::Data).to receive(:can_write?).and_raise(StandardError)
      expect(instance.data_can_write?(:tasks)).to be false
    end
  end
end
