# ExecService

`ExecService` is a full-featured Ruby service class for running and managing
subprocesses. It provides a rich interface for spawning processes, controlling
and monitoring those processes, setting up and redirecting streams, and
interpreting results. It also provides shortcuts for common cases such as
invoking Ruby in a subprocess or capturing output in a string. Use
`ExecService` when existing interfaces such as the `system()` method or the
`Open3` library are not sufficiently powerful or expressive for your needs.

## Getting started

Install `ExecService` via the
[exec_service gem](https://rubygems.org/gems/exec_service).

```sh
% gem install exec_service
```

or add it to your Gemfile:

```ruby
gem "exec_service"
```

To use the service, instantiate `ExecService`, and call the convenient methods
on it to spawn subprocesses:

```ruby
require "exec_service"
exec_service = ExecService.new
git_version = exec_service.capture(["git", "--version"]).chomp
```

## Features

 *  Execute subprocesses in the foreground (i.e. blocking until completion) or
    background (returning immediately)
 *  Fork (execute a proc in a subprocess) or spawn (specify a command to run)
 *  Environment setup for the subprocess, including
     *  Working directory
     *  Environment variables
     *  Optionally disabling any existing bundle
     *  Umask
     *  Process group
 *  Rich process control interface, including:
     *  Access to process state and results
     *  Read/write access to non-redirected streams
     *  Signalling
     *  Joining
 *  Robust setup and redirect of streams, including:
     *  Inheriting parent process streams
     *  Redirecting to/from files
     *  Redirecting to/from pipes
     *  Redirecting to/from arbitrary IO objects
     *  Redirecting error to out and vice versa
     *  Reading input from strings
     *  Capturing output streams
     *  Tees for output streams
     *  Redirecting to/from null
     *  Closing streams
 *  Rich result reporting, including exit status, signals, and exceptions
 *  Convenience methods for common use cases, including:
     *  Simple output captures
     *  Running Ruby processes
     *  Executing a string in the shell
 *  Customizable logging

## Contributing

Development is done in GitHub at https://github.com/dazuma/exec_service.

 *  To file issues: https://github.com/dazuma/exec_service/issues.
 *  For questions and discussion, please do not file an issue. Instead, use the
    discussions feature: https://github.com/dazuma/exec_service/discussions.
 *  Pull requests are welcome, but in general please open an issue first before
    contributing significant changes.

The library uses [toys](https://dazuma.github.io/toys) for testing and CI. To
run the test suite, `gem install toys` and then run `toys ci`. You can also run
unit tests, rubocop, and build tests independently.

## License

Copyright 2026 Daniel Azuma

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
IN THE SOFTWARE.
