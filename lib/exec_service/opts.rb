# frozen_string_literal: true

class ExecService
  ##
  # An internal helper class storing the configuration of a subprocess invocation
  #
  # @private
  #
  class Opts
    ##
    # Option keys that belong to exec configuration
    #
    # @private
    #
    CONFIG_KEYS = [
      :argv0,
      :background,
      :env,
      :err,
      :in,
      :logger,
      :log_cmd,
      :log_level,
      :name,
      :out,
      :result_callback,
      :unbundle,
    ].freeze

    ##
    # Option keys that belong to spawn configuration
    #
    # @private
    #
    SPAWN_KEYS = [
      :chdir,
      :close_others,
      :new_pgroup,
      :pgroup,
      :umask,
      :unsetenv_others,
    ].freeze

    ##
    # @private
    #
    def initialize(parent = nil)
      if parent
        @config_opts = ::Hash.new { |_h, k| parent.config_opts[k] }
        @spawn_opts = ::Hash.new { |_h, k| parent.spawn_opts[k] }
      elsif block_given?
        @config_opts = ::Hash.new { |_h, k| yield k }
        @spawn_opts = ::Hash.new { |_h, k| yield k }
      else
        @config_opts = {}
        @spawn_opts = {}
      end
    end

    ##
    # @private
    #
    def add(config)
      config.each do |k, v|
        if CONFIG_KEYS.include?(k)
          @config_opts[k] = v
        elsif SPAWN_KEYS.include?(k) || k.to_s.start_with?("rlimit_")
          @spawn_opts[k] = v
        else
          raise ::ArgumentError, "Unknown key: #{k.inspect}"
        end
      end
      self
    end

    ##
    # @private
    #
    def delete(*keys)
      keys.each do |k|
        if CONFIG_KEYS.include?(k)
          @config_opts.delete(k)
        elsif SPAWN_KEYS.include?(k) || k.to_s.start_with?("rlimit_")
          @spawn_opts.delete(k)
        else
          raise ::ArgumentError, "Unknown key: #{k.inspect}"
        end
      end
      self
    end

    ##
    # @private
    #
    attr_reader :config_opts

    ##
    # @private
    #
    attr_reader :spawn_opts
  end
end
