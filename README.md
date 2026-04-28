# ExecService

`ExecService` is a full-featured Ruby service class for running and managing
subprocesses. It provides a rich interface for spawning processes, controlling
and monitoring those processes, interacting with streams, and interpreting
results. It also provides shortcuts for common cases such as invoking Ruby in
a subprocess or capturing output in a string.

Use `ExecService` when simple tools such as the `system()` method are not
sufficiently powerful or expressive, or when even libraries like `Open3` don't
give you the tools you want.

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

Copyright 2021-2026 Daniel Azuma

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
