# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

`ExecService` is a Ruby gem providing a service class for spawning and managing
subprocesses, with rich stream-handling, controllers, and result objects. It
was extracted from `toys-core` and targets Ruby >= 2.7 across MRI, JRuby, and
TruffleRuby (CI also runs on macOS and Windows).

## Build / test / lint

The project uses [toys](https://dazuma.github.io/toys) for all dev tasks.
Install with `gem install toys`, then from the repo root:

- `toys test` — run the full minitest suite (`test/test_exec_service.rb`).
- `toys rubocop` — run rubocop with this repo's config (`.rubocop.yml`,
  `TargetRubyVersion: 2.7`, `LineLength: 120`).
- `toys yardoc` — build YARD docs; fails on warnings or undocumented public
  objects, so any new public method/class needs a YARD comment.
- `toys build` — build the gem into `pkg/`.
- `toys ci` — run all of the above (this is what GitHub Actions runs); pass
  `--only --test` (etc.) to run a single job, and `--update` to bundle-update
  before running.
- `toys clean` — clean per `.gitignore` (preserves `.claude/` files).

Run a single test by passing minitest's name flag through toys:
`toys test --name=/detects ENOENT/`. The suite uses `minitest-focus`, so
adding `focus` before an `it` block also works for ad-hoc isolation.

Always run `toys test` and `toys rubocop` before committing.

## Architecture

The public entry point is the single class `ExecService` in
`lib/exec_service.rb`, which holds default options and exposes the spawn
methods. Internals live under `lib/exec_service/`.

**Spawn methods on `ExecService`:**
- `exec(cmd, **opts, &block)` — primitive: spawns an OS process via
  `Process.spawn`. `cmd` is a string (shell) or array (argv).
- `exec_proc(func, **opts, &block)` — primitive: forks and runs a `Proc`. Not
  available where `Process.fork` is missing (Windows, JRuby). The `:unbundle`
  option is rejected here.
- `exec_ruby(args, **opts)` / `ruby` — convenience wrapper around `exec` using
  `RbConfig.ruby`.
- `capture` / `capture_ruby` / `capture_proc` — force `out: :capture,
  background: false` and return the captured stdout string.
- `sh(cmd, **opts)` — shell-style; returns an integer `effective_code`.

**Internal collaborators:**
- `ExecService::Opts` (`opts.rb`) splits keyword arguments into two buckets:
  `CONFIG_KEYS` (consumed by ExecService itself: `:in/:out/:err`, `:env`,
  `:background`, `:logger`, `:result_callback`, `:unbundle`, `:name`, etc.)
  and `SPAWN_KEYS` (passed straight to `Process.spawn`: `:chdir`,
  `:close_others`, `:pgroup`, `:umask`, `:unsetenv_others`, plus any
  `rlimit_*`). Unknown keys raise `ArgumentError`. `Opts` instances chain via
  a parent so `configure_defaults` flows into per-call overrides through
  default-block hashes.
- `ExecService::Executor` (`executor.rb`, `@private`) does the real work:
  interprets each `:in/:out/:err` setting, sets up pipes / capture threads /
  tee threads / null streams, calls either `Process.spawn` or `Process.fork`,
  then returns a `Controller`. Stream setup distinguishes parent-side
  (pre-spawn) from in-fork (post-fork, before `func.call`) paths because
  forked procs need `$stdin/$stdout/$stderr` reopened in-process. The tee
  implementation runs its own thread with `IO.select` and per-sink buffers.
- `ExecService::Controller` (`controller.rb`) is what users interact with
  during execution — yielded to the block in foreground mode, returned in
  background mode. It owns `@in/@out/@err` (only populated for streams
  configured `:controller`), exposes `kill`/`signal`, `capture`/`redirect`
  for late stream redirection, and `result(timeout:)` which joins the
  background completion thread. Cleanup runs in a dedicated thread that
  `Process.wait2`s the child, joins all stream threads, then builds the
  `Result` and (if background) fires `:result_callback` on yet another
  thread.
- `ExecService::Result` (`result.rb`, frozen) holds `name`, `captured_out`,
  `captured_err`, `status` (`Process::Status`), and `exception` (if spawn
  failed). Use `success?`/`error?`/`signaled?`/`failed?` for status, or
  `effective_code` for an always-integer exit code (128+sig for signals,
  127 for ENOENT, 126 for EACCES/ENOEXEC).

**Stream-handling vocabulary** (the heart of the API; see the long doc
comment at the top of `lib/exec_service.rb`): each of `:in/:out/:err` accepts
symbols (`:inherit`, `:null`, `:close`, `:capture`, `:controller`), files
(`[:file, path, mode?, perms?]`), strings/IOs/StringIOs, `IO.pipe` arrays,
child-stream merges (`[:child, :out]`), input strings (`[:string, "..."]`,
`:in` only), and `[:tee, ...]` for output fan-out. StringIO and other IOs
without a real fileno are supported via background copy threads — this is
deliberate and a key value-add over `Process.spawn`.

## Conventions

- Top-level public API lives in `ExecService`. Helper classes (`Executor`,
  `Opts`) are marked `@private` in YARD; `Controller` and `Result` are public
  but instantiated only by the framework (`initialize` is `@private`).
- All files start with `# frozen_string_literal: true`.
- Public methods need full YARD docs (`@param`/`@return`/`@yieldparam`) —
  `toys yardoc` enforces this.
- Tests use `describe`/`it` minitest spec style, wrap each test in
  `Timeout.timeout(...)` to avoid hanging the suite, and skip per-engine via
  the `jruby?` / `truffleruby?` / `windows?` / `allow_fork?` helpers in
  `test/helper.rb`. Follow this pattern for any new test.
