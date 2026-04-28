# frozen_string_literal: true

class ExecService
  ##
  # An object that controls a subprocess. This object is returned from an
  # execution running in the background, or is yielded to a control block
  # for an execution running in the foreground.
  # You can use this object to interact with the subcommand's streams,
  # send signals to the process, and get its result.
  #
  class Controller
    ##
    # The subcommand's name.
    # @return [Object]
    #
    attr_reader :name

    ##
    # The subcommand's standard input stream (which can be written to).
    #
    # @return [IO] if the command was configured with `in: :controller`
    # @return [nil] if the command was not configured with
    #     `in: :controller`
    #
    attr_reader :in

    ##
    # The subcommand's standard output stream (which can be read from).
    #
    # @return [IO] if the command was configured with `out: :controller`
    # @return [nil] if the command was not configured with
    #     `out: :controller`
    #
    attr_reader :out

    ##
    # The subcommand's standard error stream (which can be read from).
    #
    # @return [IO] if the command was configured with `err: :controller`
    # @return [nil] if the command was not configured with
    #     `err: :controller`
    #
    attr_reader :err

    ##
    # The process ID.
    #
    # Exactly one of {#exception} and {#pid} will be non-nil.
    #
    # @return [Integer] if the process start was successful
    # @return [nil] if the process could not be started.
    #
    attr_reader :pid

    ##
    # The exception raised when the process failed to start.
    #
    # Exactly one of {#exception} and {#pid} will be non-nil.
    #
    # @return [Exception] if the process failed to start.
    # @return [nil] if the process start was successful.
    #
    attr_reader :exception

    ##
    # Captures the remaining data in the given stream.
    # After calling this, do not read directly from the stream.
    #
    # @param which [:out,:err] Which stream to capture
    #
    # @return [self] if the stream was captured
    # @return [nil] if the stream was not captured because the process has
    #     completed or did not start successfully
    #
    def capture(which)
      @streams_mutex.synchronize do
        return nil unless @streams_open
        stream = stream_for(which, allow_in: false)
        @join_threads << ::Thread.new do
          data = stream.read
          @captures_mutex.synchronize do
            @captures[which] = data
          end
        ensure
          stream.close
        end
      end
      self
    end

    ##
    # Captures the remaining data in the standard output stream.
    # After calling this, do not read directly from the stream.
    #
    # @return [self]
    #
    def capture_out
      capture(:out)
    end

    ##
    # Captures the remaining data in the standard error stream.
    # After calling this, do not read directly from the stream.
    #
    # @return [self]
    #
    def capture_err
      capture(:err)
    end

    ##
    # Redirects the remainder of the given stream.
    #
    # You can specify the stream as an IO or IO-like object, or as a file
    # specified by its path. If specifying a file, you can optionally
    # provide the mode and permissions for the call to `File#open`. You can
    # also specify the value `:null` to indicate the null file.
    #
    # If the stream is redirected to an IO-like object, it is _not_ closed
    # when the process is completed. (If it is redirected to a file
    # specified by path, the file is closed on completion.)
    #
    # After calling this, do not interact directly with the stream.
    #
    # @param which [:in,:out,:err] Which stream to redirect
    # @param io [IO,StringIO,String,:null] Where to redirect the stream
    # @param io_args [Object...] The mode and permissions for opening the
    #     file, if redirecting to/from a file.
    #
    # @return [self] if the stream was redirected
    # @return [nil] if the stream was not redirected because the process
    #     has completed or did not start successfully
    #
    def redirect(which, io, *io_args)
      @streams_mutex.synchronize do
        return nil unless @streams_open
        io = ::File::NULL if io == :null
        close_afterward = false
        if io.is_a?(::String)
          io_args = which == :in ? ["r"] : ["w"] if io_args.empty?
          io = ::File.open(io, *io_args)
          close_afterward = true
        end
        stream = stream_for(which, allow_in: true)
        @join_threads << ::Thread.new do
          if which == :in
            ::IO.copy_stream(io, stream)
          else
            ::IO.copy_stream(stream, io)
          end
        ensure
          stream.close
          io.close if close_afterward
        end
      end
      self
    end

    ##
    # Redirects the remainder of the standard input stream.
    #
    # You can specify the stream as an IO or IO-like object, or as a file
    # specified by its path. If specifying a file, you can optionally
    # provide the mode and permissions for the call to `File#open`. You can
    # also specify the value `:null` to indicate the null file.
    #
    # After calling this, do not interact directly with the stream.
    #
    # @param io [IO,StringIO,String,:null] Where to redirect the stream
    # @param io_args [Object...] The mode and permissions for opening the
    #     file, if redirecting from a file.
    #
    # @return [self] if the stream was redirected
    # @return [nil] if the stream was not redirected because the process
    #     has completed or did not start successfully
    #
    def redirect_in(io, *io_args)
      redirect(:in, io, *io_args)
    end

    ##
    # Redirects the remainder of the standard output stream.
    #
    # You can specify the stream as an IO or IO-like object, or as a file
    # specified by its path. If specifying a file, you can optionally
    # provide the mode and permissions for the call to `File#open`. You can
    # also specify the value `:null` to indicate the null file.
    #
    # After calling this, do not interact directly with the stream.
    #
    # @param io [IO,StringIO,String,:null] Where to redirect the stream
    # @param io_args [Object...] The mode and permissions for opening the
    #     file, if redirecting to a file.
    #
    # @return [self] if the stream was redirected
    # @return [nil] if the stream was not redirected because the process
    #     has completed or did not start successfully
    #
    def redirect_out(io, *io_args)
      redirect(:out, io, *io_args)
    end

    ##
    # Redirects the remainder of the standard error stream.
    #
    # You can specify the stream as an IO or IO-like object, or as a file
    # specified by its path. If specifying a file, you can optionally
    # provide the mode and permissions for the call to `File#open`. You can
    # also specify the value `:null` to indicate the null file.
    #
    # After calling this, do not interact directly with the stream.
    #
    # @param io [IO,StringIO,String,:null] Where to redirect the stream
    # @param io_args [Object...] The mode and permissions for opening the
    #     file, if redirecting to a file.
    #
    # @return [self] if the stream was redirected
    # @return [nil] if the stream was not redirected because the process
    #     has completed or did not start successfully
    #
    def redirect_err(io, *io_args)
      redirect(:err, io, *io_args)
    end

    ##
    # Send the given signal to the process. The signal can be specified
    # by name or number.
    #
    # @param sig [Integer,String] The signal to send.
    # @return [self]
    #
    def kill(sig)
      ::Process.kill(sig, pid) if pid
      self
    end
    alias signal kill

    ##
    # Determine whether the subcommand is still executing
    #
    # @return [boolean]
    #
    def executing?
      @completion_thread&.status ? true : false
    end

    ##
    # Wait for the subcommand to complete, and return a result object.
    #
    # @param timeout [Numeric,nil] The timeout in seconds, or `nil` to
    #     wait indefinitely.
    # @return [ExecService::Result] The result object
    # @return [nil] if a timeout occurred.
    #
    def result(timeout: nil)
      return nil if @completion_thread && !@completion_thread.join(timeout)
      # @completion_thread sets @result, so the final value is guaranteed
      # to be stable once the thread has joined above.
      @result
    end

    ##
    # @private
    #
    def initialize(name:, controller_streams:, captures:, pid_or_exception:,
                   join_threads:, background_callback:, captures_mutex:)
      @name = name
      @in = controller_streams[:in]
      @out = controller_streams[:out]
      @err = controller_streams[:err]
      @captures = captures
      @join_threads = join_threads
      @background_callback = background_callback
      @captures_mutex = captures_mutex
      @streams_open = false
      @streams_mutex = ::Mutex.new
      @pid = @exception = @completion_thread = @result = nil
      case pid_or_exception
      when ::Integer
        @pid = pid_or_exception
        @streams_open = true
        @completion_thread = ::Thread.new do
          _pid, status = ::Process.wait2(@pid)
          cleanup(status)
        end
      when ::Exception
        @exception = pid_or_exception
        cleanup(nil)
      end
    end

    ##
    # Close the controller's input stream, if any.
    #
    # @private
    #
    def close_in_stream
      @streams_mutex.synchronize do
        @in&.close
      end
      self
    end

    ##
    # Close the controller's output streams, if any.
    #
    # @private
    #
    def close_out_streams
      @streams_mutex.synchronize do
        @out&.close
        @err&.close
      end
      self
    end

    private

    ##
    # Cleanup after the child process ends.
    # Blocks any further captures/redirects, joins all stream processing
    # threads, and sets the result. Also kicks off the callback if run in
    # the background.
    #
    def cleanup(status)
      @streams_mutex.synchronize do
        @streams_open = false
      end
      @join_threads.each(&:join)
      @result = Result.new(@name, @captures[:out], @captures[:err], status, @exception)
      if @background_callback
        ::Thread.new do
          @background_callback.call(@result)
        end
      end
    end

    def stream_for(which, allow_in: false)
      stream = nil
      case which
      when :out
        stream = @out
        @out = nil
      when :err
        stream = @err
        @err = nil
      when :in
        if allow_in
          stream = @in
          @in = nil
        end
      else
        raise ::ArgumentError, "Unknown stream #{which}"
      end
      raise ::ArgumentError, "Stream #{which} not available" unless stream
      stream
    end
  end
end
