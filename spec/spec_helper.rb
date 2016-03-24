require 'rspec'
require 'fakefs/spec_helpers'
require 'fakefs/safe'
require 'builder'
require 'pry'

Dir['./spec/helpers/*.rb'].map {|f| require f }

RSpec.configure do |config|
  config.include FakeFS::SpecHelpers

  config.expose_dsl_globally = true

  config.color = true
  config.formatter = :documentation

  Builder.logger = Logger.new('/dev/null')

  config.filter_run :focus => true
  config.run_all_when_everything_filtered = true
end
