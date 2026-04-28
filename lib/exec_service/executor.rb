# frozen_string_literal: true

class ExecService
  ##
  # An object that manages the execution of a subcommand
  #
  # @private
  #
  class Executor
    ##
    # @private
    #
    def initialize(exec_opts, spawn_cmd, block)
      @fork_func = spawn_cmd.respond_to?(:call) ? spawn_cmd : nil
      if @fork_func && !::Process.respond_to?(:fork)
        raise ::NotImplementedError,
              "Executing a proc is not available because fork is not supported on the current Ruby platform"
      end
      @spawn_cmd = spawn_cmd.respond_to?(:call) ? nil : spawn_cmd
      @config_opts = exec_opts.config_opts
      @spawn_opts = exec_opts.spawn_opts
      @captures = {}
      @controller_streams = {}
      @join_threads = []
      @child_streams = []
      @parent_streams = []
      @block = block
      @default_stream = @config_opts[:background] ? :null : :inherit
      @captures_mutex = ::Mutex.new
    end

    ##
    # @private
    #
    def execute
      setup_in_stream
      setup_out_stream(:out)
      setup_out_stream(:err)
      log_command
      controller = start_with_controller
      return controller if @config_opts[:background]
      begin
        begin
          @block&.call(controller)
        ensure
          controller.close_in_stream
        end
        result = controller.result
        @config_opts[:result_callback]&.call(result)
      ensure
        controller.close_out_streams
      end
      result
    end

    private

    def log_command
      logger = @config_opts[:logger]
      if logger && @config_opts[:log_level] != false
        cmd_str = @config_opts[:log_cmd] || default_log_str
        logger.add(@config_opts[:log_level] || ::Logger::INFO, cmd_str) if cmd_str
      end
    end

    def default_log_str
      if @fork_func
        "exec proc: #{@fork_func.inspect}"
      elsif @spawn_cmd
        if @spawn_cmd.size == 1 && @spawn_cmd.first.is_a?(::String)
          "exec sh: #{@spawn_cmd.first.inspect}"
        else
          cmd_binary = @spawn_cmd.first
          cmd_binary = cmd_binary.first if cmd_binary.is_a?(::Array)
          "exec: #{([cmd_binary] + @spawn_cmd[1..]).inspect}"
        end
      end
    end

    def start_with_controller
      pid_or_exception =
        begin
          @fork_func ? start_fork : start_process
        rescue ::StandardError => e
          e
        end
      @child_streams.each(&:close)
      background_callback = @config_opts[:result_callback] if @config_opts[:background]
      Controller.new(name: @config_opts[:name],
                     controller_streams: @controller_streams,
                     captures: @captures,
                     pid_or_exception: pid_or_exception,
                     join_threads: @join_threads,
                     background_callback: background_callback,
                     captures_mutex: @captures_mutex)
    end

    def start_process
      args = []
      args << @config_opts[:env] if @config_opts[:env]
      args.concat(@spawn_cmd)
      if @config_opts[:unbundle] && defined?(::Bundler) && ::Bundler.respond_to?(:with_unbundled_env)
        ::Bundler.with_unbundled_env do
          ::Process.spawn(*args, @spawn_opts)
        end
      else
        ::Process.spawn(*args, @spawn_opts)
      end
    end

    def start_fork
      pid = ::Process.fork
      return pid unless pid.nil?
      exit_code = -1
      begin
        setup_env_within_fork
        setup_streams_within_fork
        exit_code = run_fork_func
      rescue ::SystemExit => e
        exit_code = e.status
      rescue ::Exception => e # rubocop:disable Lint/RescueException
        warn(([e.inspect] + e.backtrace).join("\n"))
      ensure
        ::Kernel.exit!(exit_code)
      end
    end

    def run_fork_func
      catch(:result) do
        if @spawn_opts[:chdir]
          ::Dir.chdir(@spawn_opts[:chdir]) { @fork_func.call }
        else
          @fork_func.call
        end
        0
      end
    end

    def setup_env_within_fork
      env = @config_opts[:env] || {}
      if @spawn_opts[:unsetenv_others]
        ::ENV.each_key do |k|
          ::ENV.delete(k) unless env.key?(k)
        end
      end
      env.each do |k, v|
        if v.nil?
          ::ENV.delete(k.to_s)
        else
          ::ENV[k.to_s] = v.to_s
        end
      end
    end

    def setup_streams_within_fork
      @parent_streams.each(&:close)
      setup_in_stream_within_fork(@spawn_opts[:in], $stdin)
      setup_out_stream_within_fork(@spawn_opts[:out], $stdout)
      setup_out_stream_within_fork(@spawn_opts[:err], $stderr)
    end

    def setup_in_stream_within_fork(stream, stdstream)
      in_stream =
        case stream
        when ::Integer
          ::IO.open(stream)
        when ::Array
          ::File.open(*stream)
        when ::String
          ::File.open(stream, "r")
        when :close
          :close
        else
          stream if stream.respond_to?(:read)
        end
      if in_stream == :close
        stdstream.close
      elsif in_stream
        stdstream.reopen(in_stream)
      end
    end

    def setup_out_stream_within_fork(stream, stdstream)
      out_stream =
        case stream
        when ::Integer
          ::IO.open(stream)
        when ::Array
          interpret_out_array_within_fork(stream)
        when ::String
          ::File.open(stream, "w")
        when :close
          :close
        else
          stream if stream.respond_to?(:write)
        end
      if out_stream == :close
        stdstream.close
      elsif out_stream
        stdstream.reopen(out_stream)
        stdstream.sync = true
      end
    end

    def interpret_out_array_within_fork(stream)
      if stream.first == :child
        case stream[1]
        when :err
          $stderr
        when :out
          $stdout
        end
      else
        ::File.open(*stream)
      end
    end

    def setup_in_stream
      setting = @config_opts[:in] || @default_stream
      return unless setting
      case setting
      when ::Symbol
        setup_in_stream_of_type(setting, [])
      when ::Integer
        setup_in_stream_of_type(:parent, [setting])
      when ::String
        setup_in_stream_of_type(:file, [setting])
      when ::IO, ::StringIO
        interpret_in_io(setting)
      when ::Array
        interpret_in_array(setting)
      else
        raise "Unknown value for in: #{setting.inspect}"
      end
    end

    def interpret_in_io(setting)
      if setting.fileno.is_a?(::Integer)
        setup_in_stream_of_type(:parent, [setting.fileno])
      else
        setup_in_stream_of_type(:copy_io, [setting])
      end
    end

    def interpret_in_array(setting)
      if setting.first.is_a?(::Symbol)
        setup_in_stream_of_type(setting.first, setting[1..])
      elsif setting.first.is_a?(::String)
        setup_in_stream_of_type(:file, setting)
      elsif setting.size == 2 && setting.first.is_a?(::IO) && setting.last.is_a?(::IO)
        interpret_in_pipe(*setting)
      else
        raise "Unknown value for in: #{setting.inspect}"
      end
    end

    def interpret_in_pipe(reader, writer)
      @spawn_opts[:in] = reader
      @child_streams << reader
      @parent_streams << writer
    end

    def setup_in_stream_of_type(type, args)
      case type
      when :controller
        @controller_streams[:in] = make_in_pipe
      when :null
        make_null_stream(:in, "r")
      when :inherit
        @spawn_opts[:in] = :in
      when :close
        @spawn_opts[:in] = type
      when :parent
        @spawn_opts[:in] = args.first
      when :child
        @spawn_opts[:in] = [:child, args.first]
      when :string
        write_string_thread(args.first.to_s)
      when :copy_io
        copy_to_in_thread(args.first)
      when :file
        interpret_in_file(args)
      else
        raise "Unknown type for in: #{type.inspect}"
      end
    end

    def interpret_in_file(args)
      raise "Expected only file name for in" unless args.size == 1 && args.first.is_a?(::String)
      @spawn_opts[:in] = args + [::File::RDONLY]
    end

    def setup_out_stream(key)
      setting = @config_opts[key] || @default_stream
      case setting
      when ::Symbol
        setup_out_stream_of_type(key, setting, [])
      when ::Integer
        setup_out_stream_of_type(key, :parent, [setting])
      when ::String
        setup_out_stream_of_type(key, :file, [setting])
      when ::IO, ::StringIO
        interpret_out_io(key, setting)
      when ::Array
        interpret_out_array(key, setting)
      else
        raise "Unknown value for #{key}: #{setting.inspect}"
      end
    end

    def interpret_out_io(key, setting)
      if setting.fileno.is_a?(::Integer)
        setup_out_stream_of_type(key, :parent, [setting.fileno])
      else
        setup_out_stream_of_type(key, :copy_io, [setting])
      end
    end

    def interpret_out_array(key, setting)
      if setting.first.is_a?(::Symbol)
        setup_out_stream_of_type(key, setting.first, setting[1..])
      elsif setting.first.is_a?(::String)
        setup_out_stream_of_type(key, :file, setting)
      elsif setting.size == 2 && setting.first.is_a?(::IO) && setting.last.is_a?(::IO)
        interpret_out_pipe(key, *setting)
      else
        raise "Unknown value for #{key}: #{setting.inspect}"
      end
    end

    def interpret_out_pipe(key, reader, writer)
      @spawn_opts[key] = writer
      @child_streams << writer
      @parent_streams << reader
    end

    def setup_out_stream_of_type(key, type, args)
      case type
      when :controller
        @controller_streams[key] = make_out_pipe(key)
      when :null
        make_null_stream(key, "w")
      when :inherit
        @spawn_opts[key] = key
      when :close, :out, :err
        @spawn_opts[key] = type
      when :parent
        @spawn_opts[key] = args.first
      when :child
        @spawn_opts[key] = [:child, args.first]
      when :capture
        capture_stream_thread(key)
      when :copy_io
        copy_from_out_thread(key, args.first)
      when :file
        interpret_out_file(key, args)
      when :tee
        interpret_out_tee(key, args)
      else
        raise "Unknown type for #{key}: #{type.inspect}"
      end
    end

    def interpret_out_file(key, args)
      raise "Expected file name for #{key}" if args.empty? || !args.first.is_a?(::String)
      raise "Too many file arguments for #{key}" if args.size > 3
      @spawn_opts[key] = args.size == 1 ? args.first : args
    end

    def interpret_out_tee(key, args)
      opts = args.last.is_a?(::Hash) ? args.pop : {}
      reader = make_out_pipe(key)
      sinks = interpret_out_tee_arguments(key, args)
      tee_runner(key, reader, sinks, opts[:buffer_size] || 65_536)
    end

    def interpret_out_tee_arguments(key, args)
      args.map do |arg|
        case arg
        when :inherit
          [key == :err ? $stderr : $stdout, nil]
        when :capture
          [::StringIO.new, :capture]
        when :controller
          tee_sink_for_controller(key)
        when ::IO, ::StringIO
          [arg, nil]
        when ::String
          [::File.open(arg, "w"), :close]
        when ::Array
          tee_sink_for_array(key, arg)
        else
          raise "Unknown value for #{key} tee argument: #{arg.inspect}"
        end
      end
    end

    def tee_sink_for_controller(key)
      @controller_streams[key], writer = ::IO.pipe
      writer.sync = true
      [writer, :close]
    end

    def tee_sink_for_array(key, arg)
      if arg.size == 2 &&
         arg.last.is_a?(::IO) &&
         (arg.first == :autoclose || arg.first.is_a?(::IO))
        [arg.last, :close]
      else
        arg = arg[1..] if arg.first == :file
        if arg.empty? || !arg.first.is_a?(::String)
          raise "Expected file name for #{key} tee argument"
        end
        raise "Too many file arguments for #{key} tee argument" if arg.size > 3
        arg += ["w"] if arg.size == 1
        [::File.open(*arg), :close]
      end
    end

    def tee_runner(key, reader, sinks, buffer_size)
      @join_threads << ::Thread.new do
        sinks.map! { |io, on_done| [io, ::String.new, :write_nonblock, on_done] }
        until sinks.empty?
          tee_wait_for_streams(reader, sinks)
          reader = tee_read_stream(reader, sinks, buffer_size)
          tee_write_streams(sinks, key, reader.nil?)
        end
      end
    end

    def tee_wait_for_streams(reader, sinks)
      read_select = reader && [reader]
      write_select = []
      sinks.each do |io, buffer, _write_method, _on_done|
        write_select << io unless buffer.empty?
      end
      ::IO.select(read_select, write_select)
    end

    def tee_read_stream(reader, sinks, buffer_size)
      return nil if reader.nil?
      max = tee_amount_to_read(sinks, buffer_size)
      return reader unless max.positive?
      begin
        data = reader.read_nonblock(max)
        unless data.empty?
          sinks.each { |_io, buffer, _write_method, _on_done| buffer << data }
        end
        reader
      rescue ::IO::WaitReadable
        reader
      rescue ::StandardError
        reader.close rescue nil # rubocop:disable Style/RescueModifier
        nil
      end
    end

    def tee_write_streams(sinks, key, read_complete)
      sinks.delete_if do |sink|
        io, buffer, write_method, on_done = sink
        done, write_method = tee_write_one_stream(io, buffer, write_method, read_complete)
        sink[2] = write_method
        if done
          case on_done
          when :close
            io.close rescue nil # rubocop:disable Style/RescueModifier
          when :capture
            @captures_mutex.synchronize do
              @captures[key] = io.string
            end
          end
        end
        done
      end
    end

    def tee_write_one_stream(io, buffer, write_method, read_complete)
      return [read_complete, write_method] if buffer.empty?
      begin
        bytes = io.send(write_method, buffer)
        buffer.slice!(0, bytes)
        [false, write_method]
      rescue ::IO::WaitWritable, ::Errno::EINTR
        [false, write_method]
      rescue ::Errno::EBADF, ::NoMethodError
        raise if write_method == :write
        [false, :write]
      rescue ::StandardError
        [true, write_method]
      end
    end

    def tee_amount_to_read(sink_info, buffer_size)
      maxbuff = 0
      sink_info.each do |_sink, buffer, _meth|
        maxbuff = buffer.size if buffer.size > maxbuff
      end
      buffer_size - maxbuff
    end

    def make_null_stream(key, mode)
      f = ::File.open(::File::NULL, mode)
      @spawn_opts[key] = f
      @child_streams << f
    end

    def make_in_pipe
      r, w = ::IO.pipe
      @spawn_opts[:in] = r
      @child_streams << r
      @parent_streams << w
      w.sync = true
      w
    end

    def make_out_pipe(key)
      r, w = ::IO.pipe
      @spawn_opts[key] = w
      @child_streams << w
      @parent_streams << r
      r
    end

    def write_string_thread(string)
      stream = make_in_pipe
      @join_threads << ::Thread.new do
        stream.write string
      ensure
        stream.close
      end
    end

    def copy_to_in_thread(io)
      stream = make_in_pipe
      @join_threads << ::Thread.new do
        ::IO.copy_stream(io, stream)
      ensure
        stream.close
      end
    end

    def copy_from_out_thread(key, io)
      stream = make_out_pipe(key)
      @join_threads << ::Thread.new do
        ::IO.copy_stream(stream, io)
      ensure
        stream.close
      end
    end

    def capture_stream_thread(key)
      stream = make_out_pipe(key)
      @join_threads << ::Thread.new do
        data = stream.read
        @captures_mutex.synchronize do
          @captures[key] = data
        end
      ensure
        stream.close
      end
    end
  end
end
