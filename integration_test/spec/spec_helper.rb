require 'rspec'
require 'builder'
require 'pry'

Dir['./spec/helpers/*.rb'].map {|f| require f }

def ping_to(ip, limit = 20)
  trial = 0

  while trial < limit do
    if system("ping -c 1 #{ip}")
      return true
    end
    trial = trial + 1
    sleep(1)
  end

  return false
end

RSpec.configure do |config|
  config.expose_dsl_globally = true

  config.color = true
  config.formatter = :documentation

  config.filter_run :focus => true
  config.run_all_when_everything_filtered = true
end
