# frozen_string_literal: true

lib = ::File.expand_path("lib", __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require "exec_service/version"

::Gem::Specification.new do |spec|
  spec.name = "exec_service"
  spec.version = ::ExecService::VERSION
  spec.authors = ["Daniel Azuma"]
  spec.email = ["dazuma@gmail.com"]

  spec.summary = "A Ractor wrapper for a non-shareable object."
  spec.description =
    "An experimental class that wraps a non-shareable object in a Ractor," \
    " allowing multiple client Ractors to access it concurrently."
  spec.license = "MIT"
  spec.homepage = "https://github.com/dazuma/exec_service"

  spec.files = ::Dir.glob("lib/**/*.rb") +
               (::Dir.glob("*.md") - ["CLAUDE.md", "AGENTS.md"]) +
               [".yardopts"]
  spec.require_paths = ["lib"]

  spec.add_dependency "logger"
  spec.required_ruby_version = ">= 2.7"

  spec.metadata["bug_tracker_uri"] = "https://github.com/dazuma/exec_service/issues"
  spec.metadata["changelog_uri"] = "https://rubydoc.info/gems/exec_service/#{::ExecService::VERSION}/file/CHANGELOG.md"
  spec.metadata["documentation_uri"] = "https://rubydoc.info/gems/exec_service/#{::ExecService::VERSION}"
  spec.metadata["homepage_uri"] = "https://github.com/dazuma/exec_service"
end
