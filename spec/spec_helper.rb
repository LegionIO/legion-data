# frozen_string_literal: true

# begin
#   require 'simplecov'
#   SimpleCov.start do
#     add_filter '/spec/'
#     add_group 'Models', 'lib/legion/data/models'
#     add_group 'Migrations', 'lib/legion/data/migrations'
#     add_group 'Connections', 'lib/legion/data/connections'
#   end
# rescue LoadError
#   puts 'Failed to load file for coverage reports, continuing without it'
# end

require 'bundler/setup'
require 'legion/logging'
require 'legion/settings'
Legion::Logging.setup(log_file: './legion.log', level: 'fatal')
Legion::Settings.load
require 'legion/data'

test_adapter = ENV.fetch('LEGION_DATA_ADAPTER', 'sqlite')
Legion::Settings[:data][:adapter] = test_adapter
Legion::Settings[:data][:dev_mode] = false
Legion::Settings[:data][:dev_fallback] = false

case test_adapter
when 'sqlite'
  Legion::Settings[:data][:creds] = { database: 'legion_test.db' }
  FileUtils.rm_f(File.expand_path('~/.legionio/data/legion_test.db'))
when 'postgres'
  Legion::Settings[:data][:creds] = {
    host:     ENV.fetch('LEGION_DATA_HOST'),
    port:     Integer(ENV.fetch('LEGION_DATA_PORT', '5432')),
    user:     ENV.fetch('LEGION_DATA_USER'),
    password: ENV.fetch('LEGION_DATA_PASSWORD', ''),
    database: ENV.fetch('LEGION_DATA_DATABASE')
  }
else
  raise ArgumentError, "Unsupported test database adapter: #{test_adapter}"
end

Legion::Data.setup
raise "Expected #{test_adapter}, connected to #{Legion::Data.connection.database_type}" unless Legion::Data.connection.database_type.to_s == test_adapter

Legion::Data::Migration.migrate(Legion::Data::Connection.sequel,
                                File.expand_path('../lib/legion/data/migrations', __dir__))

RSpec.configure do |config|
  config.example_status_persistence_file_path = '.rspec_status'
  config.disable_monkey_patching!
  config.after(:suite) { Legion::Data.shutdown }
  config.expect_with :rspec do |c|
    c.syntax = :expect
  end
end
