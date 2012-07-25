# coding: UTF-8

require "vcap/common"
require "membrane"
require "steno"
require "steno/core_ext"

module Dea
  class Instance
    class BaseError < StandardError
    end

    class RuntimeNotFoundError < BaseError
      attr_reader :data

      def initialize(runtime)
        @data = { :runtime_name => runtime }
      end

      def message
        "Runtime not found: #{data[:runtime_name].inspect}"
      end
    end

    class TransitionError < BaseError
      attr_reader :from
      attr_reader :to

      def initialize(from, to)
        @from = from
        @to = to
      end

      def message
        "Cannot transition from #{from.inspect} to #{to.inspect}"
      end
    end

    def self.translate_attributes(attributes)
      attributes = attributes.dup

      attributes["instance_index"]      = attributes.delete("index")

      attributes["application_id"]      = attributes.delete("droplet")
      attributes["application_version"] = attributes.delete("version")
      attributes["application_name"]    = attributes.delete("name")
      attributes["application_uris"]    = attributes.delete("uris")
      attributes["application_users"]   = attributes.delete("users")

      attributes["droplet_sha1"]        = attributes.delete("sha1")
      attributes["droplet_file"]        = attributes.delete("executableFile")
      attributes["droplet_uri"]         = attributes.delete("executableUri")

      attributes["runtime_name"]        = attributes.delete("runtime")
      attributes["framework_name"]      = attributes.delete("framework")

      attributes["environment"]         = attributes.delete("env")

      attributes
    end

    def self.schema
      Membrane::SchemaParser.parse do
        {
          # Static attributes (coming from cloud controller):
          "instance_id"         => String,
          "instance_index"      => Integer,

          "application_id"      => Integer,
          "application_version" => String,
          "application_name"    => String,
          "application_uris"    => [String],
          "application_users"   => [String],

          "droplet_sha1"        => String,
          "droplet_file"        => String,
          "droplet_uri"         => String,

          "runtime_name"        => String,
          "framework_name"      => String,

          # TODO: use proper schema
          "limits"              => any,
          "environment"         => any,
          "services"            => any,
          "flapping"            => any,
          "debug"               => any,
          "console"             => any,
        }
      end
    end

    # Define an accessor for every attribute with a schema
    self.schema.schemas.each do |key, _|
      define_method(key) do
        attributes[key]
      end
    end

    attr_reader :bootstrap
    attr_reader :attributes

    def initialize(bootstrap, attributes)
      @bootstrap  = bootstrap
      @attributes = attributes.dup

      # Generate unique ID
      @attributes["instance_id"] = VCAP.secure_uuid
      @attributes["state"] = "born"
    end

    def validate
      self.class.schema.validate(@attributes)

      # Check if the runtime is available
      if bootstrap.runtimes[self.runtime_name].nil?
        error = RuntimeNotFoundError.new(self.runtime_name)
        logger.warn(error.message, error.data)
        raise error
      end
    end

    def state
      attributes["state"]
    end

    def state=(state)
      attributes["state"] = state
    end

    def droplet
      bootstrap.droplet_registry[droplet_sha1]
    end

    def start(&callback)
      promise_state = Promise.new do |p|
        if state != "born"
          p.fail(TransitionError.new("born", "start"))
        else
          p.deliver
        end
      end

      promise_droplet_download = Promise.new do |p|
        droplet.download(droplet_uri) do |error|
          if error
            p.fail(error)
          else
            p.deliver
          end
        end
      end

      promise_droplet_available = Promise.new do |p|
        unless droplet.droplet_exist?
          promise_droplet_download.resolve
        end

        p.deliver
      end

      promise_start = Promise.new do |p|
        promise_state.resolve
        promise_droplet_available.resolve
      end

      sequence(promise_start, callback)
    end

    class Promise
      attr_reader :elapsed_time

      def initialize(&blk)
        @blk = blk
        @result = nil
        @waiting = []
      end

      def fail(value)
        resume([:fail, value])

        nil
      end

      def deliver(value = nil)
        resume([:deliver, value])

        nil
      end

      def resolve
        unless @result
          wait
        end

        type, value = @result
        raise value if type == :fail
        value
      end

      protected

      def wait
        if @waiting.empty?
          run
        end

        @waiting << Fiber.current
        Fiber.yield
      end

      def resume(result)
        # Set result once
        unless @result
          @result = result
          @elapsed_time = Time.now - @start_time
        end

        # Resume from a fresh stack
        EM.next_tick do
          @waiting.each(&:resume)
          @waiting = []
        end

        nil
      end

      def run
        EM.next_tick do
          f = Fiber.new do
            begin
              @start_time = Time.now
              @blk.call(self)
            rescue => error
              fail(error)
            end
          end

          f.resume
        end
      end
    end

    def sequence(promise, callback)
      @sequence ||= []
      @sequence << [promise, callback]

      run = lambda do
        promise, callback = @sequence.first

        if promise
          f = Fiber.new do
            error = nil

            begin
              promise.resolve
            rescue => error
            end

            callback.call(error)

            # Remove completed promise from sequence
            @sequence.shift

            # Queue next promise
            run.call
          end

          EM.next_tick do
            f.resume
          end
        end
      end

      # Kickstart if this is the first promise of the sequence
      if @sequence.size == 1
        run.call
      end
    end

    private

    def logger
      tags = {
        "instance_id"         => instance_id,
        "instance_index"      => instance_index,
        "application_id"      => application_id,
        "application_version" => application_version,
        "application_name"    => application_name,
      }

      @logger ||= self.class.logger.tag(tags)
    end
  end
end