# frozen_string_literal: true

require_relative 'lib/legion/data/version'

Gem::Specification.new do |spec|
  spec.name = 'legion-data'
  spec.version       = Legion::Data::VERSION
  spec.authors       = ['Esity']
  spec.email         = ['matthewdiverson@gmail.com']

  spec.summary       = 'Manages the connects to the backend database'
  spec.description   = 'A LegionIO gem to connect to a persistent data store'
  spec.homepage      = 'https://github.com/LegionIO/legion-data'
  spec.license       = 'Apache-2.0'
  spec.required_ruby_version = '>= 3.4'
  spec.require_paths = ['lib']
  spec.files = `git ls-files -z`.split("\x0").reject { |f| f.match(%r{^(test|spec|features)/}) }
  spec.extra_rdoc_files = %w[README.md LICENSE CHANGELOG.md]
  spec.metadata = {
    'bug_tracker_uri'       => 'https://github.com/LegionIO/legion-data/issues',
    'changelog_uri'         => 'https://github.com/LegionIO/legion-data/blob/main/CHANGELOG.md',
    'documentation_uri'     => 'https://github.com/LegionIO/legion-data',
    'homepage_uri'          => 'https://github.com/LegionIO/LegionIO',
    'source_code_uri'       => 'https://github.com/LegionIO/legion-data',
    'wiki_uri'              => 'https://github.com/LegionIO/legion-data/wiki',
    'rubygems_mfa_required' => 'true'
  }

  spec.add_dependency 'csv', '>= 3.2'
  spec.add_dependency 'legion-json'
  spec.add_dependency 'legion-logging', '>= 1.5.0'
  spec.add_dependency 'legion-settings', '>= 1.5.0'
  spec.add_dependency 'sequel', '>= 5.70'
  spec.add_dependency 'sqlite3', '>= 2.0'
end
