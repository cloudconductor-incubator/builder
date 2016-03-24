# -*- coding: utf-8 -*-

setup_rb = File.expand_path("../../../vendor/bundle/bundler/setup.rb", __FILE__)

if File.exist?(setup_rb)
  require setup_rb
else
  abort "[ERROR]: builder requires 'bundle install' with '--standalone' option."
end
