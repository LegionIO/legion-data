# frozen_string_literal: true

source 'https://rubygems.org'

gemspec

settings_path = File.expand_path('../legion-settings', __dir__)
gem 'legion-settings', path: settings_path if File.directory?(settings_path)

group :test do
  gem 'legion-crypt', '>= 1.5.42'
  gem 'rake'
  gem 'rspec'
  gem 'rspec_junit_formatter'
  gem 'rubocop-legion'
  gem 'simplecov'
end
gem 'mysql2', '>= 0.5.5'
gem 'pg', '>= 1.5'
