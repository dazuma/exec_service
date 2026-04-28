# frozen_string_literal: true

source "https://rubygems.org"

gemspec

minitest_versions = ::RUBY_VERSION < "3.1" ? ["~> 5.26"] : [">= 5.26", "< 7"]
gem "minitest", *minitest_versions
gem "minitest-focus", "~> 1.4", ">= 1.4.1"
gem "minitest-rg", "~> 5.4"
gem "redcarpet", "~> 3.6", ">= 3.6.1" unless ::RUBY_PLATFORM == "java"
gem "rubocop", "~> 1.82", ">= 1.82.1"
gem "yard", "~> 0.9", ">= 0.9.38"
