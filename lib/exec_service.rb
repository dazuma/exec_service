# frozen_string_literal: true

require "exec_service/controller"
require "exec_service/executor"
require "exec_service/opts"
require "exec_service/result"

##
# A service that executes subprocesses.
#
# This service provides a convenient interface for controlling spawned
# processes and their streams. It also provides shortcuts for common cases
# such as invoking Ruby in a subprocess or capturing output in a string.
#
# ### The exec service
#
# The main entrypoint class is this one, {ExecService}. It is a "service"
# object that provides functionality, primarily methods that spawn processes.
# Create it like any object:
#
#     require "exec_service"
#     exec_service = ExecService.new
#
# There are two "primitive" functions: {#exec} and {#exec_proc}. The {#exec}
# method spawns an operating system process specified by an executable and
# a set of arguments. The {#exec_proc} method takes a `Proc` and forks a
# Ruby process. Both of these can be heavily configured with stream
# handling, result handling, and numerous other options described below.
# The class also provides convenience methods for common cases such as
# spawning a Ruby process, spawning a shell script, or capturing output.
#
# The exec service class also stores default configuration that it applies
# to processes it spawns. You can set these defaults when constructing the
# service class, or at any time by calling {#configure_defaults}.
#
# ### Stream handling
#
# By default, subprocess streams are connected to the corresponding streams
# in the parent process. You can change this behavior, redirecting streams
# or providing ways to control them, using the `:in`, `:out`, and `:err`
# options.
#
# Three general strategies are available for custom stream handling. First,
# you can redirect to other streams such as files, IO objects, or Ruby
# strings. Some of these options map directly to options provided by the
# `Process#spawn` method. Second, you can use a controller to manipulate
# the streams programmatically. Third, you can capture output stream data
# and make it available in the result.
#
# Following is a full list of the stream handling options, along with how
# to specify them using the `:in`, `:out`, and `:err` options.
#
#  *  **Inherit parent stream:** You can inherit the corresponding stream
#     in the parent process by passing `:inherit` as the option value. This
#     is the default if the subprocess is run in the foreground.
#
#  *  **Redirect to null:** You can redirect to a null stream by passing
#     `:null` as the option value. This connects to a stream that is not
#     closed but contains no data, i.e. `/dev/null` on unix systems. This
#     is the default if the subprocess is run in the background.
#
#  *  **Close the stream:** You can close the stream by passing `:close` as
#     the option value. This is the same as passing `:close` to
#     `Process#spawn`.
#
#  *  **Redirect to a file:** You can redirect to a file. This reads from
#     an existing file when connected to `:in`, and creates or appends to a
#     file when connected to `:out` or `:err`. To specify a file, use the
#     setting `[:file, "/path/to/file"]`. You can also, when writing a
#     file, append an optional mode and permission code to the array. For
#     example, `[:file, "/path/to/file", "a", 0644]`.
#
#  *  **Redirect to an IO object:** You can redirect to an IO object in the
#     parent process, by passing the IO object as the option value. You can
#     use any IO object. For example, you could connect the child's output
#     to the parent's error using `out: $stderr`, or you could connect to
#     an existing File stream. Unlike `Process#spawn`, this works for IO
#     objects that do not have a corresponding file descriptor (such as
#     StringIO objects). In such a case, a thread will be spawned to pipe
#     the IO data through to the child process. Note that the IO object
#     will _not_ be closed on completion.
#
#  *  **Redirect to a pipe:** You can redirect to a pipe created using
#     `IO.pipe` (i.e. a two-element array of read and write IO objects) by
#     passing the array as the option value. This will connect the
#     appropriate IO (either read or write), and close it in the parent.
#     Thus, you can connect only one process to each end. If you want more
#     direct control over IO closing behavior, pass the IO object (i.e. the
#     element of the pipe array) directly.
#
#  *  **Combine with another child stream:** You can redirect one child
#     output stream to another, to combine them. To merge the child's error
#     stream into its output stream, use `err: [:child, :out]`.
#
#  *  **Read from a string:** You can pass a string to the input stream by
#     setting `[:string, "the string"]`. This works only for `:in`.
#
#  *  **Capture output stream:** You can capture a stream and make it
#     available on the {ExecService::Result} object, using the
#     setting `:capture`. This works only for the `:out` and `:err`
#     streams.
#
#  *  **Use the controller:** You can hook a stream to the controller using
#     the setting `:controller`. You can then manipulate the stream via the
#     controller. If you pass a block to {ExecService#exec}, it
#     yields the {ExecService::Controller}, giving you access to
#     streams. See the section below on controlling processes.
#
#  *  **Make copies of an output stream:** You can "tee," or duplicate the
#     `:out` or `:err` stream and redirect those copies to various
#     destinations. To specify a tee, use the setting `[:tee, ...]` where
#     the additional array elements include two or more of the following.
#     See the corresponding documentation above for more detail.
#      *  `:inherit` to direct to the parent process's stream.
#      *  `:capture` to capture the stream and store it in the result.
#      *  `:controller` to direct the stream to the controller.
#      *  `[:file, "/path/to/file"]` to write to a file.
#      *  An `IO` or `StringIO` object.
#      *  An array of two `IO` objects representing a pipe
#
#     Additionally, the last element of the array can be a hash of options.
#     Supported options include:
#      *  `:buffer_size` The size of the memory buffer for each element of
#         the tee. Larger buffers may allow higher throughput. The default
#         is 65536.
#
# ### Controlling processes
#
# A process can be started in the *foreground* or the *background*. If you
# start a foreground process, it will inherit your standard input and
# output streams by default, and it will keep control until it completes.
# If you start a background process, its streams will be redirected to null
# by default, and control will be returned to you immediately.
#
# While a process is running, you can control it using a
# {ExecService::Controller} object. Use a controller to interact with
# the process's input and output streams, send it signals, or wait for it
# to complete.
#
# When running a process in the foreground, the controller will be yielded
# to an optional block. For example, the following code starts a process in
# the foreground and passes its output stream to a controller.
#
#     exec_service.exec(["git", "init"], out: :controller) do |controller|
#       loop do
#         line = controller.out.gets
#         break if line.nil?
#         puts "Got line: #{line}"
#       end
#     end
#
# At the end of the block, if the controller is handling the process's
# input stream, that stream will automatically be closed. The following
# example programmatically sends data to the `wc` unix program, and
# captures its output. Because the controller is handling the input stream,
# it automatically closes the stream at the end of the block, which causes
# `wc` to end.
#
#     result = exec_service.exec(["wc"],
#                                in: :controller,
#                                out: :capture) do |controller|
#       controller.in.puts "Hello, world!"
#     end
#     puts "Results: #{result.captured_out}"
#
# Otherwise, depending on the process's behavior, it may continue to run
# after the end of the block. Control will not be returned to the caller
# until the process actually terminates. Conversely, it is also possible
# the process could terminate by itself while the block is still executing.
# You can call controller methods to obtain the process's actual current
# state.
#
# When running a process in the background, the controller is returned
# immediately from the method that starts the process. In the following
# example, git init is kicked off in the background and the output is
# thrown away to /dev/null.
#
#     controller = exec_service.exec(["git", "init"], background: true)
#
# In this mode, use the returned controller to query the process's state
# and interact with it. Streams directed to the controller are not
# automatically closed, so you will need to do so yourself. Following is an
# example of running `wc` in the background:
#
#     controller = exec_service.exec(["wc"], background: true,
#                                    in: :controller, out: :controller)
#     controller.in.puts "Hello, world!"
#     controller.in.close # Do this explicitly to cause wc to finish
#     puts "Results: #{controller.out.read}" # Read the entire stream
#
# ### Result handling
#
# A subprocess result is represented by a {ExecService::Result}
# object, which includes the exit code, the content of any captured output
# streams, and any exception raised when attempting to run the process.
# When you run a process in the foreground, the method will return a result
# object. When you run a process in the background, you can obtain the
# result from the controller once the process completes.
#
# The following example demonstrates running a process in the foreground
# and getting the exit code:
#
#     result = exec_service.exec(["git", "init"])
#     puts "exit code: #{result.exit_code}"
#
# The following example demonstrates starting a process in the background,
# waiting for it to complete, and getting its exit code:
#
#     controller = exec_service.exec(["git", "init"], background: true)
#     result = controller.result(timeout: 1.0)
#     if result
#       puts "exit code: #{result.exit_code}"
#     else
#       puts "timed out"
#     end
#
# You can also provide a callback that is executed once a process
# completes. For example:
#
#     my_callback = proc do |result|
#       puts "exit code: #{result.exit_code}"
#     end
#     exec_service.exec(["git", "init"], result_callback: my_callback)
#
# In foreground mode, the callback is executed in the calling thread, after
# the process terminates (and after any controller block has completed) but
# before control is returned to the caller. In background mode, the
# callback is executed asynchronously in a separate thread after the
# process terminates.
#
# ### Configuration options
#
# A variety of options can be used to control subprocesses. These can be
# provided to any method that starts a subprocess. You can also set
# defaults by calling {ExecService#configure_defaults}.
#
# Options that affect the behavior of subprocesses:
#
#  *  `:env` (Hash) Environment variables to pass to the subprocess.
#     Keys represent variable names and should be strings. Values should be
#     either strings or `nil`, which unsets the variable.
#
#  *  `:background` (boolean) Runs the process in the background if `true`.
#
#  *  `:result_callback` (Proc) Called and passed the result object when
#     the subprocess exits. If the process was run in the background, this
#     callback is executed in a separate thread. If the process was run in
#     the foreground, this callback is executed in the calling thread.
#
#  *  `:unbundle` (boolean) Disables any existing bundle when running the
#     subprocess. Has no effect if Bundler isn't active at the call point.
#     Cannot be used when executing in a fork, e.g. via {#exec_proc}.
#
# Options for connecting input and output streams. See the section above on
# stream handling for info on the values that can be passed.
#
#  *  `:in` Connects the input stream of the subprocess. See the section on
#     stream handling.
#
#  *  `:out` Connects the standard output stream of the subprocess. See the
#     section on stream handling.
#
#  *  `:err` Connects the standard error stream of the subprocess. See the
#     section on stream handling.
#
# Options related to logging and reporting:
#
#  *  `:logger` (Logger) Logger to use for logging the actual command. If
#     not present, the command is not logged.
#
#  *  `:log_level` (Integer,false) Level for logging the actual command.
#     Defaults to Logger::INFO if not present. You can also pass `false` to
#     disable logging of the command.
#
#  *  `:log_cmd` (String) The string logged for the actual command.
#     Defaults to the `inspect` representation of the command.
#
#  *  `:name` (Object) An optional object that can be used to identify this
#     subprocess. It is available in the controller and result objects.
#
# In addition, the following options recognized by
# [`Process#spawn`](https://ruby-doc.org/core/Process.html#method-c-spawn)
# are supported.
#
#  *  `:chdir` (String) Set the working directory for the command.
#
#  *  `:close_others` (boolean) Whether to close non-redirected
#     non-standard file descriptors.
#
#  *  `:new_pgroup` (boolean) Create new process group (Windows only).
#
#  *  `:pgroup` (Integer,true,nil) The process group setting.
#
#  *  `:umask` (Integer) Umask setting for the new process.
#
#  *  `:unsetenv_others` (boolean) Clear environment variables except those
#     explicitly set.
#
# Any other option key will result in an `ArgumentError`.
#
class ExecService
  ##
  # Create an exec service.
  #
  # @param block [Proc] A block that is called if a key is not found. It is
  #     passed the unknown key, and expected to return a default value
  #     (which can be nil).
  # @param opts [keywords] Initial default options. See {ExecService}
  #     for a description of the options.
  #
  def initialize(**opts, &block)
    require "logger"
    require "rbconfig"
    require "stringio"
    @default_opts = Opts.new(&block).add(opts)
  end

  ##
  # Set default options. See {ExecService} for a description of the
  # options.
  #
  # @param opts [keywords] New default options to set
  # @return [self]
  #
  def configure_defaults(**opts)
    @default_opts.add(opts)
    self
  end

  ##
  # Execute a command. The command can be given as a single string to pass
  # to a shell, or an array of strings indicating a posix command.
  #
  # If the process is not set to run in the background, and a block is
  # provided, a {ExecService::Controller} will be yielded to it.
  #
  # @param cmd [String,Array<String>] The command to execute.
  # @param opts [keywords] The command options. See the section on
  #     configuration options in the {ExecService} class docs.
  # @yieldparam controller [ExecService::Controller] A controller
  #     for the subprocess streams.
  #
  # @return [ExecService::Controller] The subprocess controller, if
  #     the process is running in the background.
  # @return [ExecService::Result] The result, if the process ran in
  #     the foreground.
  #
  def exec(cmd, **opts, &block)
    exec_opts = Opts.new(@default_opts).add(opts)
    spawn_cmd =
      if cmd.is_a?(::Array)
        if cmd.size > 1
          binary = canonical_binary_spec(cmd.first, exec_opts)
          [binary] + cmd[1..].map(&:to_s)
        else
          [canonical_binary_spec(Array(cmd.first), exec_opts)]
        end
      else
        [cmd.to_s]
      end
    executor = Executor.new(exec_opts, spawn_cmd, block)
    executor.execute
  end

  ##
  # Spawn a ruby process and pass the given arguments to it.
  #
  # If the process is not set to run in the background, and a block is
  # provided, a {ExecService::Controller} will be yielded to it.
  #
  # @param args [String,Array<String>] The arguments to ruby.
  # @param opts [keywords] The command options. See the section on
  #     configuration options in the {ExecService} class docs.
  # @yieldparam controller [ExecService::Controller] A controller
  #     for the subprocess streams.
  #
  # @return [ExecService::Controller] The subprocess controller, if
  #     the process is running in the background.
  # @return [ExecService::Result] The result, if the process ran in
  #     the foreground.
  #
  def exec_ruby(args, **opts, &block)
    cmd = args.is_a?(::Array) ? [::RbConfig.ruby] + args : "#{::RbConfig.ruby} #{args}"
    log_cmd = "exec ruby: #{args.inspect}"
    opts = {argv0: "ruby", log_cmd: log_cmd}.merge(opts)
    exec(cmd, **opts, &block)
  end
  alias ruby exec_ruby

  ##
  # Execute a proc in a fork.
  #
  # If the process is not set to run in the background, and a block is
  # provided, a {ExecService::Controller} will be yielded to it.
  #
  # @param func [Proc] The proc to call.
  # @param opts [keywords] The command options. See the section on
  #     configuration options in the {ExecService} class docs.
  # @yieldparam controller [ExecService::Controller] A controller
  #     for the subprocess streams.
  #
  # @return [ExecService::Controller] The subprocess controller, if
  #     the process is running in the background.
  # @return [ExecService::Result] The result, if the process ran in
  #     the foreground.
  #
  def exec_proc(func, **opts, &block)
    raise ::ArgumentError, "Given proc is not callable" unless func.respond_to?(:call)
    exec_opts = Opts.new(@default_opts).add(opts)
    raise ::ArgumentError, "Cannot use :unbundle option with exec_proc" if exec_opts.config_opts[:unbundle]
    executor = Executor.new(exec_opts, func, block)
    executor.execute
  end

  ##
  # Execute a command. The command can be given as a single string to pass
  # to a shell, or an array of strings indicating a posix command.
  #
  # Captures standard out and returns it as a string.
  # Cannot be run in the background.
  #
  # If a block is provided, a {ExecService::Controller} will be
  # yielded to it.
  #
  # @param cmd [String,Array<String>] The command to execute.
  # @param opts [keywords] The command options. See the section on
  #     configuration options in the {ExecService} class docs.
  # @yieldparam controller [ExecService::Controller] A controller
  #     for the subprocess streams.
  #
  # @return [String] What was written to standard out.
  #
  def capture(cmd, **opts, &block)
    opts = opts.merge(out: :capture, background: false)
    exec(cmd, **opts, &block).captured_out
  end

  ##
  # Spawn a ruby process and pass the given arguments to it.
  #
  # Captures standard out and returns it as a string.
  # Cannot be run in the background.
  #
  # If a block is provided, a {ExecService::Controller} will be
  # yielded to it.
  #
  # @param args [String,Array<String>] The arguments to ruby.
  # @param opts [keywords] The command options. See the section on
  #     configuration options in the {ExecService} class docs.
  # @yieldparam controller [ExecService::Controller] A controller
  #     for the subprocess streams.
  #
  # @return [String] What was written to standard out.
  #
  def capture_ruby(args, **opts, &block)
    opts = opts.merge(out: :capture, background: false)
    ruby(args, **opts, &block).captured_out
  end

  ##
  # Execute a proc in a fork.
  #
  # Captures standard out and returns it as a string.
  # Cannot be run in the background.
  #
  # If a block is provided, a {ExecService::Controller} will be
  # yielded to it.
  #
  # @param func [Proc] The proc to call.
  # @param opts [keywords] The command options. See the section on
  #     configuration options in the {ExecService} class docs.
  # @yieldparam controller [ExecService::Controller] A controller
  #     for the subprocess streams.
  #
  # @return [String] What was written to standard out.
  #
  def capture_proc(func, **opts, &block)
    opts = opts.merge(out: :capture, background: false)
    exec_proc(func, **opts, &block).captured_out
  end

  ##
  # Execute the given string in a shell. Returns an effective exit code
  # that is always an integer. Cannot be run in the background.
  #
  # If a block is provided, a {ExecService::Controller} will be
  # yielded to it.
  #
  # @param cmd [String] The shell command to execute.
  # @param opts [keywords] The command options. See the section on
  #     configuration options in the {ExecService} class docs.
  # @yieldparam controller [ExecService::Controller] A controller
  #     for the subprocess streams.
  #
  # @return [Integer] An effective exit code. See
  #     {ExecService::Result#effective_code}.
  #
  def sh(cmd, **opts, &block)
    opts = opts.merge(background: false)
    exec(cmd, **opts, &block).effective_code
  end

  private

  def canonical_binary_spec(cmd, exec_opts)
    config_argv0 = exec_opts.config_opts[:argv0]
    return cmd.to_s if !config_argv0 && !cmd.is_a?(::Array)
    cmd = Array(cmd)
    actual_cmd = cmd.first
    argv0 = cmd[1] || config_argv0 || actual_cmd
    [actual_cmd.to_s, argv0.to_s]
  end
end
