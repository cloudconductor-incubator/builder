
require 'thor'
require 'yaml'
require 'logger'

require_relative 'ext/hash'

def db
  Builder.db
end

def config
  Builder.config
end

module Builder

  ROOT = ENV['BUILDER_ROOT'] || File.expand_path("../../", __FILE__)

  class << self
    attr_accessor :logger
    attr_accessor :db
    attr_accessor :config
  end

  module Cli
    autoload :Root, 'builder/cli/root'
  end

  module Hypervisors
    autoload :Kvm, 'builder/hypervisors/kvm'
    autoload :Aws, 'builder/hypervisors/aws'
  end

  module Helpers
    autoload :Config, 'builder/helpers/config'
    autoload :Logger, 'builder/helpers/logger'
  end
end

Builder.logger ||= ::Logger.new(STDOUT)
