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

Legion::Settings[:data][:adapter] = 'sqlite'
Legion::Settings[:data][:dev_mode] = true
Legion::Settings[:data][:creds] ||= {}
Legion::Settings[:data][:creds][:database] = 'legion_test.db'

db_path = File.expand_path('~/.legionio/data/legion_test.db')
FileUtils.rm_f(db_path)

Legion::Data.setup
Legion::Data::Migration.migrate(Legion::Data::Connection.sequel,
                                File.expand_path('../lib/legion/data/migrations', __dir__))

RSpec.configure do |config|
  config.example_status_persistence_file_path = '.rspec_status'
  config.disable_monkey_patching!
  config.expect_with :rspec do |c|
    c.syntax = :expect
  end
end
