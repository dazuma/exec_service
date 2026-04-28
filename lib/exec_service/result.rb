# frozen_string_literal: true

class ExecService
  ##
  # The result returned from a subcommand execution. This includes the
  # identifying name of the execution (if any), the result status of the
  # execution, and any captured stream output.
  #
  # Possible result statuses are:
  #
  #  *  The process failed to start. {Result#failed?} will return true, and
  #     {Result#exception} will return an exception describing the failure
  #     (often an errno).
  #  *  The process executed and exited with a normal exit code. Either
  #     {Result#success?} or {Result#error?} will return true, and
  #     {Result.exit_code} will return the numeric exit code.
  #  *  The process executed but was terminated by an uncaught signal.
  #     {Result#signaled?} will return true, and {Result#signal_code} will
  #     return the numeric signal code.
  #
  class Result
    ##
    # The subcommand's name.
    #
    # @return [Object]
    #
    attr_reader :name

    ##
    # The captured output string.
    #
    # @return [String] The string captured from stdout.
    # @return [nil] if the command was not configured to capture stdout.
    #
    attr_reader :captured_out

    ##
    # The captured error string.
    #
    # @return [String] The string captured from stderr.
    # @return [nil] if the command was not configured to capture stderr.
    #
    attr_reader :captured_err

    ##
    # The Ruby process status object, providing various information about
    # the ending state of the process.
    #
    # Exactly one of {#exception} and {#status} will be non-nil.
    #
    # @return [Process::Status] The status, if the process was successfully
    #     spawned and terminated.
    # @return [nil] if the process could not be started.
    #
    attr_reader :status

    ##
    # The exception raised if a process couldn't be started.
    #
    # Exactly one of {#exception} and {#status} will be non-nil.
    # Exactly one of {#exception}, {#exit_code}, or {#signal_code} will be
    # non-nil.
    #
    # @return [Exception] The exception raised from process start.
    # @return [nil] if the process started successfully.
    #
    attr_reader :exception

    ##
    # The numeric status code for a process that exited normally,
    #
    # Exactly one of {#exception}, {#exit_code}, or {#signal_code} will be
    # non-nil.
    #
    # @return [Integer] the numeric status code, if the process started
    #     successfully and exited normally.
    # @return [nil] if the process did not start successfully, or was
    #     terminated by an uncaught signal.
    #
    def exit_code
      status&.exitstatus
    end

    ##
    # The numeric signal code that caused process termination.
    #
    # Exactly one of {#exception}, {#exit_code}, or {#signal_code} will be
    # non-nil.
    #
    # @return [Integer] The signal that caused the process to terminate.
    # @return [nil] if the process did not start successfully, or executed
    #     and exited with a normal exit code.
    #
    def signal_code
      status&.termsig
    end
    alias term_signal signal_code

    ##
    # Returns true if the subprocess failed to start, or false if the
    # process was able to execute.
    #
    # @return [boolean]
    #
    def failed?
      status.nil?
    end

    ##
    # Returns true if the subprocess terminated due to an unhandled signal,
    # or false if the process failed to start or exited normally.
    #
    # @return [boolean]
    #
    def signaled?
      !signal_code.nil?
    end

    ##
    # Returns true if the subprocess terminated with a zero status, or
    # false if the process failed to start, terminated due to a signal, or
    # returned a nonzero status.
    #
    # @return [boolean]
    #
    def success?
      code = exit_code
      !code.nil? && code.zero?
    end

    ##
    # Returns true if the subprocess terminated with a nonzero status, or
    # false if the process failed to start, terminated due to a signal, or
    # returned a zero status.
    #
    # @return [boolean]
    #
    def error?
      code = exit_code
      !code.nil? && !code.zero?
    end

    ##
    # Returns an "effective" exit code, which is always an integer if the
    # process has terminated for any reason. In general, this code will be:
    #
    # * The same as {#exit_code} if the process terminated normally with an
    #   exit code,
    # * The convention of `128+signalnum` if the process terminated due to
    #   a signal,
    # * The convention of 126 if the process could not start due to lack of
    #   execution permissions,
    # * The convention of 127 if the process could not start because the
    #   command was not recognized or could not be found, or
    # * An undefined value between 1 and 255 for other failures.
    #
    # Note that the normal exit code and signal number cases are stable,
    # but any other cases are subject to change on future releases.
    #
    # @return [Integer]
    #
    def effective_code
      code = exit_code
      return code unless code.nil?
      code = signal_code
      return code + 128 unless code.nil?
      case exception
      when ::Errno::ENOENT
        127
      else
        # This is the intended result for ENOEXEC/EACCES.
        # For now, any other error (e.g. EBADARCH on MacOS) will also map
        # to this result. We can change this in the future since the
        # documentation explicitly allows it.
        126
      end
    end

    ##
    # @private
    #
    def initialize(name, out, err, status, exception)
      @name = name
      @captured_out = out
      @captured_err = err
      @status = status
      @exception = exception
      freeze
    end
  end
end
