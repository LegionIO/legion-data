# frozen_string_literal: true

source 'https://rubygems.org'

gemspec

local_root = File.directory?(File.expand_path('.ci-dependencies', __dir__)) ? File.expand_path('.ci-dependencies', __dir__) : File.expand_path('..', __dir__)
settings_path = File.join(local_root, 'legion-settings')
gem 'legion-settings', path: settings_path if File.file?(File.join(settings_path, 'legion-settings.gemspec'))

group :test do
  gem 'rake'
  gem 'rspec'
  gem 'rspec_junit_formatter'
  gem 'rubocop-legion'
  gem 'simplecov'
end
gem 'mysql2', '>= 0.5.5'
gem 'pg', '>= 1.5'
