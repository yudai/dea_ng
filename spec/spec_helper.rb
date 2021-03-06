# coding: UTF-8

$:.unshift(File.expand_path("../../buildpacks/lib", __FILE__))

require 'bundler'
Bundler.require

require 'tempfile'
require_relative '../buildpacks/lib/buildpack'

Dir["#{File.dirname(__FILE__)}/support/**/*.rb"].map { |f| require f }

RSpec.configure do |config|
  config.include Helpers
  config.include StagingSpecHelpers, :type => :buildpack

  config.before do
    steno_config = {
      :default_log_level => :all,
      :codec => Steno::Codec::Json.new,
      :context => Steno::Context::Null.new
    }

    if ENV.has_key?("V")
      steno_config[:sinks] = [Steno::Sink::IO.new(STDERR)]
    end

    Steno.init(Steno::Config.new(steno_config))
  end
end

STAGING_TEMP = Dir.mktmpdir

at_exit do
  if File.directory?(STAGING_TEMP)
    FileUtils.rm_r(STAGING_TEMP)
  end
end
