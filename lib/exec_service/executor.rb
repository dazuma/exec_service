# frozen_string_literal: true

class ExecService
  ##
  # An object that manages the execution of a subcommand
  #
  # @private
  #
  class Executor
    ##
    # Build an executor for a single subprocess invocation. Captures the
    # caller-resolved options, the command (either an argv array for
    # `Process.spawn` or a callable for `Process.fork`), and the optional
    # controller block. Initializes the bookkeeping state used during
    # {#execute} (capture map, controller stream map, helper threads, child
    # vs parent stream tracking, default stream behavior).
    #
    # @private
    #
    # @param exec_opts [ExecService::Opts] Resolved per-call options.
    # @param spawn_cmd [Array<String>,Proc] Either the argv to spawn, or a
    #     callable to invoke in a fork.
    # @param block [Proc,nil] The optional controller block (only used in
    #     foreground mode).
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
    # Run the subprocess. Sets up all three standard streams, logs the
    # command, spawns/forks, and wraps the result in a {Controller}. In
    # background mode returns the controller immediately; in foreground mode
    # yields the controller to the user block (closing its `:in` stream
    # afterward), waits for completion, fires `:result_callback`, closes the
    # controller's output streams, and returns the {Result}.
    #
    # @private
    #
    # @return [ExecService::Controller] if running in the background.
    # @return [ExecService::Result] if running in the foreground.
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

    ##
    # Emit the command line to the configured `:logger` at `:log_level`
    # (default `Logger::INFO`). No-op if no logger is set or `:log_level` is
    # `false`. Uses `:log_cmd` if provided, otherwise falls back to
    # {#default_log_str}.
    #
    # @return [void]
    #
    def log_command
      logger = @config_opts[:logger]
      if logger && @config_opts[:log_level] != false
        cmd_str = @config_opts[:log_cmd] || default_log_str
        logger.add(@config_opts[:log_level] || ::Logger::INFO, cmd_str) if cmd_str
      end
    end

    ##
    # Build the default human-readable log string for this invocation,
    # depending on whether this is a fork-of-proc, a shell string, or an argv.
    # Strips the argv0 override (the second element of `[bin, argv0]`) when
    # rendering an argv form so the log shows the actual binary.
    #
    # @return [String,nil] Log string, or nil if there is nothing to log.
    #
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

    ##
    # Start the subprocess (via {#start_process} or {#start_fork}), close the
    # parent's references to the child-side IO ends so the child can detect
    # EOF properly, and construct a {Controller} wrapping the resulting pid
    # (or the spawn exception). Background mode forwards the result callback
    # to the controller for async firing.
    #
    # @return [ExecService::Controller]
    #
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

    ##
    # Spawn the OS process. Prepends the env hash if any was configured, and
    # wraps the call in `Bundler.with_unbundled_env` when `:unbundle` is set
    # and Bundler is loaded.
    #
    # @return [Integer] The pid of the spawned process.
    #
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

    ##
    # Fork a child process for {#run_fork_func}. In the parent, returns the
    # child pid. In the child, applies env/stream setup, invokes the user
    # proc, and exits via `Kernel.exit!` (skipping at_exit handlers) with the
    # proc's return value, a `SystemExit` status, or -1 on uncaught
    # exceptions.
    #
    # @return [Integer] The child pid (in the parent process). Does not
    #     return in the child.
    #
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

    ##
    # Invoke the user proc inside the fork, honoring `:chdir` if given.
    # Wrapped in `catch(:result)` so the proc may `throw :result, code` to
    # short-circuit; otherwise the proc's return value is discarded and 0 is
    # used.
    #
    # @return [Integer] The exit code to use for the forked child.
    #
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

    ##
    # Apply the configured `:env` hash inside the fork. If
    # `:unsetenv_others` is set, first delete every existing variable not
    # named in the configured env. Nil values delete; everything else is
    # coerced to string.
    #
    # @return [void]
    #
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

    ##
    # In-fork stream setup. Closes parent-side IO ends (the child no longer
    # needs them) and reopens `$stdin`/`$stdout`/`$stderr` per the resolved
    # spawn-options translation that {#setup_in_stream} / {#setup_out_stream}
    # produced on the parent side.
    #
    # @return [void]
    #
    def setup_streams_within_fork
      @parent_streams.each(&:close)
      setup_in_stream_within_fork(@spawn_opts[:in], $stdin)
      setup_out_stream_within_fork(@spawn_opts[:out], $stdout)
      setup_out_stream_within_fork(@spawn_opts[:err], $stderr)
    end

    ##
    # Reopen stdin in the fork according to the parent-resolved spawn-opt
    # value (which may be an fd Integer, a `[path, mode]` array, a path
    # String, `:close`, or a readable IO). Anything else is ignored.
    #
    # @param stream [Object] The parent-resolved spawn-opt value.
    # @param stdstream [IO] The standard stream to reopen (typically
    #     `$stdin`).
    # @return [void]
    #
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

    ##
    # Reopen stdout/stderr in the fork. Mirrors {#setup_in_stream_within_fork}
    # for output: fd Integer, `[path, mode, perms]` array (delegated to
    # {#interpret_out_array_within_fork}), path String, `:close`, or a
    # writable IO. Sets `sync = true` on the reopened stream.
    #
    # @param stream [Object] The parent-resolved spawn-opt value.
    # @param stdstream [IO] The standard stream to reopen (typically
    #     `$stdout` or `$stderr`).
    # @return [void]
    #
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

    ##
    # Decode an array-shaped output spawn-opt inside the fork. Specifically
    # handles `[:child, :out]` / `[:child, :err]` (alias another std stream
    # in this child) and falls through to `File.open(*stream)` for file
    # specifications.
    #
    # @param stream [Array] The array spawn-opt value.
    # @return [IO] The IO to reopen with.
    #
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

    ##
    # Top-level dispatch for the configured `:in` setting. Translates user
    # syntax (Symbol / Integer / String / IO / StringIO / Array) into a call
    # to {#setup_in_stream_of_type} or one of the array/IO interpreters.
    # Defaults to `:inherit` (foreground) or `:null` (background).
    #
    # @return [void]
    #
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

    ##
    # Decide how to plug an IO/StringIO `:in` value into the child: real
    # OS-backed IOs are passed by fd, others are pumped through a copy
    # thread (so e.g. StringIO works).
    #
    # @param setting [IO,StringIO] The IO supplied as the `:in` setting.
    # @return [void]
    #
    def interpret_in_io(setting)
      if setting.fileno.is_a?(::Integer)
        setup_in_stream_of_type(:parent, [setting.fileno])
      else
        setup_in_stream_of_type(:copy_io, [setting])
      end
    end

    ##
    # Decode an array-shaped `:in` setting. Handles `[:type, *args]`,
    # `["path", mode?, perms?]` (file), and `[reader_io, writer_io]` (a
    # pre-built `IO.pipe`).
    #
    # @param setting [Array] The array setting value.
    # @return [void]
    #
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

    ##
    # Wire an explicit user-provided pipe (reader, writer pair) into stdin:
    # the reader becomes the child's stdin and is closed in the parent on
    # spawn; the writer is closed in the parent before forking.
    #
    # @param reader [IO] The read end (handed to the child).
    # @param writer [IO] The write end (closed in the parent).
    # @return [void]
    #
    def interpret_in_pipe(reader, writer)
      @spawn_opts[:in] = reader
      @child_streams << reader
      @parent_streams << writer
    end

    ##
    # Apply a stdin setup of the given symbolic type. The dispatch covers
    # all canonical `:in` modes: controller pipe, null device, inherit-from
    # parent, close, raw fd ("parent"), child-stream alias, literal string
    # input, copy-from-IO thread, and file path.
    #
    # @param type [Symbol] The mode (`:controller`, `:null`, `:inherit`,
    #     `:close`, `:parent`, `:child`, `:string`, `:copy_io`, `:file`).
    # @param args [Array] Mode-specific arguments.
    # @return [void]
    #
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

    ##
    # Validate and apply a `:file`-typed `:in` setup. Forces read-only mode
    # and rejects extra args; only a single path String is accepted (mode
    # and perms are deliberately not user-configurable on stdin).
    #
    # @param args [Array<String>] One-element array containing the path.
    # @return [void]
    #
    def interpret_in_file(args)
      raise "Expected only file name for in" unless args.size == 1 && args.first.is_a?(::String)
      @spawn_opts[:in] = args + [::File::RDONLY]
    end

    ##
    # Top-level dispatch for `:out` or `:err`. Symmetric to
    # {#setup_in_stream} but with the additional `:tee` and `:capture` modes
    # available (and `:string` / `:copy_io` for input not present here).
    #
    # @param key [Symbol] Either `:out` or `:err`.
    # @return [void]
    #
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

    ##
    # Output counterpart to {#interpret_in_io}: real-fd IOs hook directly,
    # everything else gets a copy-from-pipe thread.
    #
    # @param key [Symbol] Either `:out` or `:err`.
    # @param setting [IO,StringIO] The user-supplied IO.
    # @return [void]
    #
    def interpret_out_io(key, setting)
      if setting.fileno.is_a?(::Integer)
        setup_out_stream_of_type(key, :parent, [setting.fileno])
      else
        setup_out_stream_of_type(key, :copy_io, [setting])
      end
    end

    ##
    # Decode an array-shaped `:out`/`:err` setting: `[:type, *args]`,
    # `["path", mode?, perms?]`, or a `[reader, writer]` pipe pair.
    #
    # @param key [Symbol] Either `:out` or `:err`.
    # @param setting [Array] The array setting value.
    # @return [void]
    #
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

    ##
    # Output counterpart to {#interpret_in_pipe}. The writer becomes the
    # child's output stream; the reader is preserved in the parent for the
    # caller to use, and is closed there at execution-end cleanup.
    #
    # @param key [Symbol] Either `:out` or `:err`.
    # @param reader [IO] The read end (kept in parent).
    # @param writer [IO] The write end (handed to the child).
    # @return [void]
    #
    def interpret_out_pipe(key, reader, writer)
      @spawn_opts[key] = writer
      @child_streams << writer
      @parent_streams << reader
    end

    ##
    # Apply an `:out` or `:err` setup of the given symbolic type. Covers
    # controller pipe, null, inherit, close/swap-with-other-stream, raw fd,
    # child-alias, capture-to-string, copy-to-IO thread, file, and tee.
    #
    # @param key [Symbol] Either `:out` or `:err`.
    # @param type [Symbol] The mode.
    # @param args [Array] Mode-specific arguments.
    # @return [void]
    #
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

    ##
    # Validate and apply a `:file`-typed `:out`/`:err` setup. Accepts one to
    # three args (`path`, optional `mode`, optional `perms`); collapses the
    # single-path case to a bare String spawn-opt for `Process.spawn`'s
    # canonical form.
    #
    # @param key [Symbol] Either `:out` or `:err`.
    # @param args [Array] `[path, mode?, perms?]`.
    # @return [void]
    #
    def interpret_out_file(key, args)
      raise "Expected file name for #{key}" if args.empty? || !args.first.is_a?(::String)
      raise "Too many file arguments for #{key}" if args.size > 3
      @spawn_opts[key] = args.size == 1 ? args.first : args
    end

    ##
    # Apply a `:tee` setup. Pulls an optional trailing options Hash off the
    # arg list, builds a pipe (the child writes here, the tee thread reads
    # from it), interprets each remaining arg into a `[sink_io, on_done]`
    # pair via {#interpret_out_tee_arguments}, and starts the fan-out
    # thread.
    #
    # @param key [Symbol] Either `:out` or `:err`.
    # @param args [Array] Sink specs followed by an optional options Hash.
    # @return [void]
    #
    def interpret_out_tee(key, args)
      opts = args.last.is_a?(::Hash) ? args.pop : {}
      reader = make_out_pipe(key)
      sinks = interpret_out_tee_arguments(key, args)
      tee_runner(key, reader, sinks, opts[:buffer_size] || 65_536)
    end

    ##
    # Resolve each tee-arg into a `[sink_io, on_done]` pair, where
    # `on_done` is one of `nil` (leave open), `:close` (close the IO when
    # this sink finishes), or `:capture` (snapshot the StringIO into the
    # captures hash).
    #
    # @param key [Symbol] Either `:out` or `:err`.
    # @param args [Array] The sink specs to interpret.
    # @return [Array<Array>] One `[io, on_done]` pair per sink.
    #
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

    ##
    # Build a tee sink for the `:controller` case: an internal pipe whose
    # read end is exposed via the controller, and whose write end is closed
    # by the tee thread when the sink completes.
    #
    # @param key [Symbol] Either `:out` or `:err`.
    # @return [Array] `[writer_io, :close]`.
    #
    def tee_sink_for_controller(key)
      @controller_streams[key], writer = ::IO.pipe
      writer.sync = true
      [writer, :close]
    end

    ##
    # Build a tee sink from an Array spec. Two recognized shapes:
    #   * `[:autoclose, io]` or `[some_io, io]` — use `io` and close it at
    #     end. (The first form is a bit historical; both branches simply
    #     take `arg.last` as the sink and mark it for close.)
    #   * `[path, mode?, perms?]` (optionally prefixed with `:file`) —
    #     opened as a file with default mode `"w"`.
    #
    # @param key [Symbol] Either `:out` or `:err`.
    # @param arg [Array] The array sink spec.
    # @return [Array] `[io, :close]`.
    #
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

    ##
    # Spawn the fan-out thread that drives the tee. Each sink is tracked as
    # `[io, buffer, write_method, on_done]`. The loop alternates an
    # `IO.select` wait, a non-blocking read from the source pipe into every
    # sink's buffer, and a non-blocking write from each sink's buffer into
    # its IO. Sinks drop out of the list when they finish (EOF reached and
    # buffer drained, or the sink errored). The thread is registered with
    # `@join_threads` so {Controller#cleanup} waits on it before producing
    # the {Result}.
    #
    # @param key [Symbol] Either `:out` or `:err`.
    # @param reader [IO] The pipe read end attached to the child's output.
    # @param sinks [Array<Array>] `[io, on_done]` pairs from
    #     {#interpret_out_tee_arguments}.
    # @param buffer_size [Integer] Per-sink memory buffer cap.
    # @return [Thread]
    #
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

    ##
    # Block until either the reader has data or some sink has buffered
    # bytes ready to flush, using `IO.select`.
    #
    # @param reader [IO,nil] The source pipe; nil once EOF was reached.
    # @param sinks [Array<Array>] Per-sink state tuples.
    # @return [void]
    #
    def tee_wait_for_streams(reader, sinks)
      read_select = reader && [reader]
      write_select = []
      sinks.each do |io, buffer, _write_method, _on_done|
        write_select << io unless buffer.empty?
      end
      ::IO.select(read_select, write_select)
    end

    ##
    # Read up to the available headroom (`buffer_size` minus the largest
    # in-flight buffer, see {#tee_amount_to_read}) from the source pipe and
    # append the data into every sink's buffer. Returns `nil` to signal EOF
    # (or any unexpected error) so the caller can flag read-complete; on
    # `WaitReadable` simply returns the reader to retry next iteration.
    #
    # @param reader [IO,nil] The source pipe, or nil if EOF already
    #     reached.
    # @param sinks [Array<Array>] Per-sink state tuples.
    # @param buffer_size [Integer] Per-sink buffer cap.
    # @return [IO,nil] The reader to use next iteration, or nil at EOF.
    #
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

    ##
    # Drive each sink one step: write whatever it can, mutating the
    # write-method in the tuple if a fallback is needed (see
    # {#tee_write_one_stream}). Drop sinks that have finished, running
    # their `on_done` action (close the io, or capture its String into the
    # captures hash).
    #
    # @param sinks [Array<Array>] Per-sink state tuples (mutated in-place).
    # @param key [Symbol] Either `:out` or `:err`.
    # @param read_complete [Boolean] True once the source pipe hit EOF.
    # @return [void]
    #
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

    ##
    # Attempt one nonblocking write from a sink's buffer. If the sink
    # doesn't support `write_nonblock` (some StringIOs / pseudo-IOs), fall
    # back permanently to plain `write`. Treats `WaitWritable`/`EINTR` as
    # "try again later". Returns `[done, write_method]`: `done` is true
    # when the sink should be removed (buffer empty and source EOF, or
    # unrecoverable error).
    #
    # @param io [IO,StringIO] The sink IO.
    # @param buffer [String] Pending bytes (mutated in-place).
    # @param write_method [Symbol] `:write_nonblock` or `:write`.
    # @param read_complete [Boolean] True if the source pipe is done.
    # @return [Array] `[done, write_method]`.
    #
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

    ##
    # Compute how many bytes the next read may pull, so that no sink's
    # buffer exceeds `buffer_size`. Returns the headroom against the
    # currently-fullest buffer (which may be zero or negative — the caller
    # treats non-positive values as "skip the read this round").
    #
    # @param sink_info [Array<Array>] Per-sink state tuples.
    # @param buffer_size [Integer] Per-sink buffer cap.
    # @return [Integer] Bytes to read this iteration.
    #
    def tee_amount_to_read(sink_info, buffer_size)
      maxbuff = 0
      sink_info.each do |_sink, buffer, _meth|
        maxbuff = buffer.size if buffer.size > maxbuff
      end
      buffer_size - maxbuff
    end

    ##
    # Open `File::NULL` in the given mode and wire it to the named
    # spawn-opt key. Tracked as a child stream so it gets closed in the
    # parent after spawn.
    #
    # @param key [Symbol] One of `:in`, `:out`, `:err`.
    # @param mode [String] File open mode (`"r"` for `:in`, `"w"` for the
    #     others).
    # @return [void]
    #
    def make_null_stream(key, mode)
      f = ::File.open(::File::NULL, mode)
      @spawn_opts[key] = f
      @child_streams << f
    end

    ##
    # Build a stdin pipe: the read end goes to the child (and is closed in
    # the parent post-spawn), the write end is exposed to the parent (and
    # is closed there during execution-end cleanup). The writer is set to
    # `sync = true` so caller writes don't buffer indefinitely.
    #
    # @return [IO] The write end (parent-side).
    #
    def make_in_pipe
      r, w = ::IO.pipe
      @spawn_opts[:in] = r
      @child_streams << r
      @parent_streams << w
      w.sync = true
      w
    end

    ##
    # Build an output pipe for `:out` or `:err`: write end goes to the
    # child, read end is exposed parent-side.
    #
    # @param key [Symbol] Either `:out` or `:err`.
    # @return [IO] The read end (parent-side).
    #
    def make_out_pipe(key)
      r, w = ::IO.pipe
      @spawn_opts[key] = w
      @child_streams << w
      @parent_streams << r
      r
    end

    ##
    # Spawn a helper thread that pumps a literal String into the child's
    # stdin and then closes the pipe (so the child sees EOF). Registered
    # with `@join_threads`.
    #
    # @param string [String] The bytes to send.
    # @return [Thread]
    #
    def write_string_thread(string)
      stream = make_in_pipe
      @join_threads << ::Thread.new do
        stream.write string
      ensure
        stream.close
      end
    end

    ##
    # Spawn a helper thread that copies from a user-supplied readable
    # object (typically a non-fd-backed IO like StringIO) into the child's
    # stdin pipe, closing the pipe at end. Registered with `@join_threads`.
    #
    # @param io [IO,StringIO] The source.
    # @return [Thread]
    #
    def copy_to_in_thread(io)
      stream = make_in_pipe
      @join_threads << ::Thread.new do
        ::IO.copy_stream(io, stream)
      ensure
        stream.close
      end
    end

    ##
    # Spawn a helper thread that copies from the child's `:out`/`:err`
    # pipe into a user-supplied writable object (typically a non-fd-backed
    # IO like StringIO), closing the pipe at end. Registered with
    # `@join_threads`.
    #
    # @param key [Symbol] Either `:out` or `:err`.
    # @param io [IO,StringIO] The destination.
    # @return [Thread]
    #
    def copy_from_out_thread(key, io)
      stream = make_out_pipe(key)
      @join_threads << ::Thread.new do
        ::IO.copy_stream(stream, io)
      ensure
        stream.close
      end
    end

    ##
    # Spawn a helper thread that drains the child's `:out`/`:err` pipe
    # entirely into a String and stores it in `@captures` (under the mutex
    # shared with the controller). Registered with `@join_threads`.
    #
    # @param key [Symbol] Either `:out` or `:err`.
    # @return [Thread]
    #
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
