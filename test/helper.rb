# frozen_string_literal: true

require "minitest/autorun"
require "minitest/focus"
require "minitest/rg"

require "exec_service"

class ExecService
  module TestHelper
    def jruby?
      ::RUBY_ENGINE == "jruby"
    end

    def truffleruby?
      ::RUBY_ENGINE == "truffleruby"
    end

    def windows?
      ::RbConfig::CONFIG["host_os"] =~ /mswin|msys|mingw|cygwin|bccwin|wince|emc/
    end

    def allow_fork?
      ::Process.respond_to?(:fork)
    end
  end
end
