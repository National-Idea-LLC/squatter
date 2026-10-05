# Plan 002: Put the `lsof` subprocess behind a testable seam and cover it with tests

> **Notion tracking — 2026-09-06:** Current task tracking is in Notion: [Squatter](https://app.notion.com/p/3d3cacb0997081acbbbbfc2bd0f0ddf8), [Tasks](https://app.notion.com/p/3d2cacb09970808d99b7f3c0c0a36f35). Any Linear URLs, IDs, statuses or refusals below are historical references. Resolve migrated IDs via `Linear ID` and verify `Project`; use the Notion task page for all new updates. This supersedes instructions below to create, query, update or close Linear issues. Follow the current repository tracking rule, including its owner-review requirements.

> **Executor instructions**: Follow this plan step by step. Run every verification
> command and confirm the expected result before moving to the next step. If anything
> in the "STOP conditions" section occurs, stop and report — do not improvise. When
> done, update the status row for this plan in `plans/README.md`.
>
> **Drift check (run first)**:
> `git diff --stat 9c7eef2..HEAD -- Squatter/Services/LsofRunner.swift Squatter/Services/PortScanner.swift SquatterTests/PortScannerTests.swift project.yml`
> If any of those files changed since this plan was written, compare the "Current state"
> excerpts below against the live code before proceeding; on a mismatch, treat it as a
> STOP condition.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: LOW
- **Depends on**: none (but plan 003 depends on this one)
- **Category**: tests
- **Planned at**: commit `9c7eef2`, 2026-08-28

## Why this matters

`LsofRunner` is the app's only subprocess and its single point of contact with the
outside world: it launches `/usr/sbin/lsof`, drains two pipes concurrently, and reports
an exit code. Every listener the app ever shows comes through it. It currently has **zero
unit tests**. The only coverage is `PortScannerTests.realLsofRunsAndProducesFieldOutput`,
which runs the real binary on the developer's machine and asserts almost nothing — it
cannot exercise a launch failure, a non-zero exit with stderr, or an output large enough
to fill a pipe buffer (the exact scenario the concurrent-drain code exists to prevent).

The reason it is untested is structural: the executable path and arguments are `static let`
constants with no injection point, so a test cannot aim it at anything but `lsof`. This
plan separates the *mechanics* of running a child process from the *policy* of which
command to run. `LsofRunner` keeps hardcoding the one fixed command — the project's golden
rule #7 ("`lsof` is invoked by absolute path with fixed arguments via `Process`, never a
shell") is preserved verbatim — while the reusable machinery underneath becomes reachable
from tests.

This started as a **behaviour-preserving refactor plus new tests**, and steps 1-2 still are.
Step 2b is not: writing test 5 uncovered a **real deadlock** in the existing drain, and the
owner decided on 2026-08-28 to fix it here rather than defer it. See step 2b.
Plan 003 (a timeout for a hung `lsof`) depends on the seam this creates.

## Current state

- `Squatter/Services/LsofRunner.swift` — defines `CommandResult`, the `CommandRunning`
  protocol, the `ScanError` enum, and `LsofRunner` itself. 84 lines, the whole file.
- `Squatter/Services/PortScanner.swift` — the actor that calls it. Its initialiser defaults
  to `runner: any CommandRunning = LsofRunner()`. **This plan does not change PortScanner.**
- `SquatterTests/PortScannerTests.swift` — where the one real-`lsof` integration test lives.

### `Squatter/Services/LsofRunner.swift:36-84` — the whole runner

```swift
/// Runs the one fixed `lsof` command. Absolute path, fixed arguments, no shell, no user input.
struct LsofRunner: CommandRunning {
    static let executablePath = "/usr/sbin/lsof"
    static let arguments = ["-nP", "-iTCP", "-sTCP:LISTEN", "+c0", "-F", "pcunPT"]

    func run() async throws -> CommandResult {
        guard FileManager.default.isExecutableFile(atPath: Self.executablePath) else {
            throw ScanError.lsofNotFound(path: Self.executablePath)
        }

        let process = Process()
        process.executableURL = URL(filePath: Self.executablePath)
        process.arguments = Self.arguments
        process.environment = [:]
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice

        // Register for termination before launching so a fast exit can't be missed.
        let exited = Task<Void, Never> {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                process.terminationHandler = { _ in continuation.resume() }
            }
        }

        do {
            try process.run()
        } catch {
            exited.cancel()
            throw ScanError.launchFailed(error.localizedDescription)
        }

        // Drain both pipes concurrently so a large listing can't fill a pipe and stall lsof.
        async let stdout = Self.readToEnd(stdoutPipe.fileHandleForReading)
        async let stderr = Self.readToEnd(stderrPipe.fileHandleForReading)
        let (out, err) = try await (stdout, stderr)
        await exited.value

        return CommandResult(stdout: out, stderr: err, exitCode: process.terminationStatus)
    }

    private static func readToEnd(_ handle: FileHandle) async throws -> Data {
        var data = Data()
        for try await byte in handle.bytes { data.append(byte) }
        return data
    }
}
```

### `Squatter/Services/LsofRunner.swift:1-34` — the surrounding types (unchanged by this plan)

```swift
/// Captured result of a finished child process.
struct CommandResult: Sendable, Equatable {
    let stdout: Data
    let stderr: Data
    let exitCode: Int32
}

/// Anything that can produce `lsof` output. `LsofRunner` is the real one; tests inject fakes.
protocol CommandRunning: Sendable {
    func run() async throws -> CommandResult
}

/// Why a scan could not produce a listener list. Messages follow the "what / why / next" rule.
enum ScanError: Error, Equatable, Sendable, LocalizedError {
    case lsofNotFound(path: String)
    case launchFailed(String)
    case nonZeroExit(code: Int32, stderr: String)
    case outputNotUTF8
    ...
}
```

### Conventions you must match

Inlined from `AGENTS.md` — you have not read it:

- **Golden rule #7, verbatim**: "Never spawn a shell. `lsof` is invoked by absolute path
  with fixed arguments via `Process`." Production code must never build a command line from
  a string, never invoke `/bin/sh`, and never read an executable path from user input or
  `UserDefaults`. The new type introduced below takes its path and arguments as stored
  properties supplied at construction — in production, only ever from `LsofRunner`'s
  constants. Say so in its doc comment.
- **Zero third-party dependencies.** Foundation and the Swift standard library only.
- **Swift 6, strict concurrency complete, warnings are errors** (`SWIFT_TREAT_WARNINGS_AS_ERRORS: YES`).
  Anything the new type captures across a concurrency boundary must be `Sendable`.
- **Tests use Swift Testing** (`@Test`, `#expect`, `#require`), never XCTest. See
  `SquatterTests/PortScannerTests.swift` for the exact idiom this repo uses, including
  `await #expect(throws: ScanError.launchFailed("boom")) { try await scanner.scan() }`.
- **New test files must be registered with `xcodegen`.** `project.yml` declares
  `sources: - path: SquatterTests`, but XcodeGen resolves that at generation time, not at
  build time: the committed `.pbxproj` enumerates every test file explicitly (there are no
  `PBXFileSystemSynchronizedRootGroup` entries). A new `.swift` file in `SquatterTests/` is
  therefore **not compiled** until you run `xcodegen generate` from the repo root. Do this
  after creating the file, and never edit `project.yml` — it already says everything it needs
  to. *(Corrected 2026-08-28: an earlier revision of this plan claimed the pickup was
  automatic. It is not; an executor lost a run to it.)*
- **Comment density**: this repo comments *why*, not *what*. Match it.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Build | `xcodebuild -project Squatter.xcodeproj -scheme Squatter -configuration Debug build` | exit 0, no warnings |
| Test | `xcodebuild -project Squatter.xcodeproj -scheme Squatter -destination 'platform=macOS' test` | exit 0; **69 tests** before your changes, **76** after |

Run from the repo root.

## Scope

**In scope**:
- `Squatter/Services/LsofRunner.swift`
- `SquatterTests/LsofRunnerTests.swift` (create)
- `Squatter.xcodeproj/project.pbxproj` — **only** as the output of `xcodegen generate`, to
  register the new test file. Never hand-edit it.
- `TRACKER.md` and `CHANGELOG.md` (step 5)

**Out of scope** (do NOT touch):
- `Squatter/Services/PortScanner.swift` — its `runner: any CommandRunning = LsofRunner()`
  default keeps working unchanged. If you find yourself editing it, you have changed
  `LsofRunner`'s public shape, which this plan forbids.
- `SquatterTests/PortScannerTests.swift` — including
  `realLsofRunsAndProducesFieldOutput`; leave it exactly as it is.
- `CommandResult`, `CommandRunning`, `ScanError` — no new cases, no changed messages.
  Plan 003 adds a `ScanError` case; this plan must not.
- `project.yml` — it already declares `sources: - path: SquatterTests`; regeneration alone
  picks the new file up. If you want to edit it, STOP and report.
- (`CHANGELOG.md` was previously listed here as out of scope, on the assumption this plan
  was invisible to users. Step 2b changed that — see the in-scope list.)

## Git workflow

**Do not commit anything.** This repo gates commits behind owner approval
(`rules/core-workflow.md`). Leave every change in the working tree and report what you
changed. Do not `git add`, commit, push, or open a PR. Do not update Linear — note in your
report that `TRACKER.md` changed and the owner needs to mirror it.

## Steps

### Step 1: Extract `ProcessRunner`

In `Squatter/Services/LsofRunner.swift`, add a new `ProcessRunner` struct **above**
`LsofRunner`. Move the entire body of `LsofRunner.run()` and the `readToEnd` helper into
it verbatim, changing only `Self.executablePath` → `executablePath` and
`Self.arguments` → `arguments`:

```swift
/// Runs one child process to completion and captures both output streams.
///
/// The executable path and arguments are fixed at construction and are never derived from
/// user input: in production the only caller is `LsofRunner`, which supplies its own
/// constants. Nothing here parses a command line or spawns a shell.
struct ProcessRunner: Sendable {
    let executablePath: String
    let arguments: [String]

    func run() async throws -> CommandResult {
        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            throw ScanError.lsofNotFound(path: executablePath)
        }

        let process = Process()
        process.executableURL = URL(filePath: executablePath)
        process.arguments = arguments
        process.environment = [:]
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice

        // Register for termination before launching so a fast exit can't be missed.
        let exited = Task<Void, Never> {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                process.terminationHandler = { _ in continuation.resume() }
            }
        }

        do {
            try process.run()
        } catch {
            exited.cancel()
            throw ScanError.launchFailed(error.localizedDescription)
        }

        // Drain both pipes concurrently so a large listing can't fill a pipe and stall the child.
        async let stdout = Self.readToEnd(stdoutPipe.fileHandleForReading)
        async let stderr = Self.readToEnd(stderrPipe.fileHandleForReading)
        let (out, err) = try await (stdout, stderr)
        await exited.value

        return CommandResult(stdout: out, stderr: err, exitCode: process.terminationStatus)
    }

    private static func readToEnd(_ handle: FileHandle) async throws -> Data {
        var data = Data()
        for try await byte in handle.bytes { data.append(byte) }
        return data
    }
}
```

`ScanError.lsofNotFound` is deliberately reused for a missing executable even though the
type is now generic: the app runs exactly one subprocess, and inventing a parallel error
case would change user-facing messages that `ScanErrorTests`-style expectations already
pin. Add a one-line comment saying so above the `guard`.

**Verify**: `xcodebuild -project Squatter.xcodeproj -scheme Squatter -configuration Debug build`
→ exit 0. (`LsofRunner` still has its own copy of `run()` at this point; that is fine and
temporary.)

### Step 2: Reduce `LsofRunner` to the fixed command

Replace the body of `LsofRunner` so it holds the constants and delegates:

```swift
/// Runs the one fixed `lsof` command. Absolute path, fixed arguments, no shell, no user input.
struct LsofRunner: CommandRunning {
    static let executablePath = "/usr/sbin/lsof"
    static let arguments = ["-nP", "-iTCP", "-sTCP:LISTEN", "+c0", "-F", "pcunPT"]

    private let process = ProcessRunner(
        executablePath: LsofRunner.executablePath,
        arguments: LsofRunner.arguments
    )

    func run() async throws -> CommandResult { try await process.run() }
}
```

Delete `LsofRunner`'s old `run()` body and its `readToEnd` helper — they now live in
`ProcessRunner`.

**Verify**:
- `grep -c "Process()" Squatter/Services/LsofRunner.swift` → `1` (only `ProcessRunner` constructs one)
- `xcodebuild -project Squatter.xcodeproj -scheme Squatter -destination 'platform=macOS' test`
  → exit 0, **69 tests** pass. This is a pure refactor: the count must not change and no
  existing test may need editing.

### Step 2b: Fix the drain deadlock

**Added 2026-08-28 by owner decision.** The `readToEnd` you moved in step 1 is broken, and
test 5 below is what exposes it. Reproduced standalone, with no Squatter code involved:

| child stdout | stderr piped? | result |
|---|---|---|
| 32 KB | yes | fine, 0.01 s |
| 60 KB | yes | fine, 0.00 s |
| **128 KB** | **yes** | **hangs forever** |
| 256 KB | no (`/dev/null`) | fine, 0.01 s |

`FileHandle.bytes` serialises its reads across handles, so `async let` does **not** actually
drain the two pipes concurrently. The stderr drain blocks waiting for output the child will
not write until it exits, while the child blocks writing into a full 64 KB stdout pipe.
Neither side can move. The existing comment claiming this design prevents a stall is exactly
backwards.

Replace `ProcessRunner.readToEnd` with a blocking read per pipe, each on its own thread:

```swift
    /// Each pipe is drained by a blocking read on its own thread. The obvious
    /// `for try await byte in handle.bytes` version deadlocks: `FileHandle.bytes`
    /// serialises reads across handles, so the stderr drain waits for output the child
    /// won't write until it exits, while the child blocks writing to a full 64 KB stdout
    /// pipe. Measured: 128 KB of stdout hung forever; this moves 4 MB in ~6 ms.
    private static func readToEnd(_ handle: FileHandle) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                do { continuation.resume(returning: try handle.readToEnd() ?? Data()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
```

Also update the drain comment above the `async let` lines, which currently claims the old
design was safe:

```swift
        // Drain both pipes on separate threads so a large listing can't fill a pipe and
        // stall the child. See readToEnd — doing this with FileHandle.bytes deadlocks.
```

**Do NOT** substitute `Task.detached { try handle.readToEnd() }`. It looks equivalent and is
shorter, but it puts a blocking read on Swift's cooperative thread pool, which is sized to
the core count — two of them plus the app's other work can starve the pool. `DispatchQueue.global()`
grows its thread pool under blocking work; that is the property being relied on here.

**Verify**: `xcodebuild -project Squatter.xcodeproj -scheme Squatter -destination 'platform=macOS' test`
→ exit 0, **69 tests** still pass (the new tests do not exist yet).

**STOP** if the compiler rejects this under `SWIFT_TREAT_WARNINGS_AS_ERRORS: YES` with a
`Sendable` complaint about capturing `handle` or `continuation`. It compiled clean under
`-swift-version 6` when this step was written, so a failure means something differs — report
the exact diagnostic. Do **not** reach for `@unchecked Sendable` or `nonisolated(unsafe)`.

### Step 3: Write the tests

Create `SquatterTests/LsofRunnerTests.swift`. See the "Test plan" section below for the
exact cases. Model the file's structure on `SquatterTests/PortScannerTests.swift`: a plain
`struct LsofRunnerTests { @Test func ... }` with `import Foundation`, `import Testing`,
`@testable import Squatter`.

**Verify**: `xcodebuild -project Squatter.xcodeproj -scheme Squatter -destination 'platform=macOS' test`
→ exit 0, **76 tests** pass.

### Step 4: Confirm the invariant still holds by inspection

**Verify** all three, each must be true:
- `grep -rn "/bin/sh\|/bin/bash\|/usr/bin/env" Squatter/` → no matches
- `grep -n "executablePath" Squatter/Services/PortScanner.swift` → no matches
- `grep -n "ProcessRunner(" Squatter/` → exactly one match, the initialiser inside `LsofRunner`

### Step 5: Update the tracking doc

`TRACKER.md` — add a new entry at the **top** of the "Dev changelog" list (newest first),
in the style of its neighbours:

```
- **2026-08-28** — Split the subprocess mechanics out of `LsofRunner` into a `ProcessRunner` that takes its executable path and arguments at construction, leaving `LsofRunner` as the fixed-command wrapper so golden rule #7 still reads the same, and regenerated `Squatter.xcodeproj` to register the new test file. Writing the large-output test exposed a real deadlock: `FileHandle.bytes` serialises reads across handles, so the `async let` drain was never actually concurrent and any child writing more than the 64 KB pipe buffer to stdout hung forever — measured, 128 KB never returned. Each pipe is now drained by a blocking read on its own thread (4 MB in ~6 ms). 7 tests, 76 total.
```

`CHANGELOG.md` — add one bullet under `## [Unreleased]` → `### Fixed`. Users have not hit
this (today's `lsof` output is ~1.2 KB against a 64 KB threshold), so keep it plain and do
not oversell it:

```
- Squatter no longer freezes on machines with a very large number of listening ports.
```

**Verify**: `grep -c "ProcessRunner" TRACKER.md` → `1`; `grep -n "large number of listening ports" CHANGELOG.md` → one match under `### Fixed`

## Test plan

New file `SquatterTests/LsofRunnerTests.swift`, seven tests. Every command used is a system
binary invoked by absolute path with fixed arguments — no shell, in tests either. The
expected values below were verified on macOS 27 at the time this plan was written.

1. `capturesStdoutAndExitCodeOfASuccessfulCommand()`
   `ProcessRunner(executablePath: "/bin/echo", arguments: ["hello", "ports"])`
   → `result.exitCode == 0`, `String(data: result.stdout, encoding: .utf8) == "hello ports\n"`,
   `result.stderr.isEmpty`.

2. `capturesNonZeroExitAndStderr()`
   `ProcessRunner(executablePath: "/bin/ls", arguments: ["/nonexistent-path-for-test"])`
   → `result.exitCode == 1`, `result.stdout.isEmpty`, and the stderr string contains
   `"No such file or directory"`. Assert with `contains`, not equality — the exact wording
   is the OS's, not ours.

3. `missingExecutableThrowsLsofNotFound()`
   `ProcessRunner(executablePath: "/usr/sbin/definitely-not-lsof", arguments: [])`
   → `await #expect(throws: ScanError.lsofNotFound(path: "/usr/sbin/definitely-not-lsof")) { try await runner.run() }`.

4. `nonExecutableFileThrowsLsofNotFound()`
   `ProcessRunner(executablePath: "/etc/hosts", arguments: [])` — `/etc/hosts` exists but is
   not executable, so this covers the `isExecutableFile` branch distinctly from case 3.
   → throws `ScanError.lsofNotFound(path: "/etc/hosts")`.

5. `largeOutputDoesNotDeadlockTheDrain()` — the regression test for the concurrent-drain
   design. `ProcessRunner(executablePath: "/bin/dd", arguments: ["if=/dev/zero", "bs=1024", "count=256"])`
   → `result.stdout.count == 262_144` and `result.exitCode == 0`. `dd` also writes its
   summary to stderr, so additionally assert `!result.stderr.isEmpty` — that proves both
   pipes drained. 256 KB is well past the 64 KB pipe buffer that would stall a sequential
   reader.

6. `emptyOutputIsNotAnError()`
   `ProcessRunner(executablePath: "/usr/bin/true", arguments: [])`
   → `result.exitCode == 0`, `result.stdout.isEmpty`, `result.stderr.isEmpty`.

7. `lsofRunnerUsesTheFixedCommand()` — a guard against someone loosening the invariant
   later. Assert `LsofRunner.executablePath == "/usr/sbin/lsof"` and
   `LsofRunner.arguments == ["-nP", "-iTCP", "-sTCP:LISTEN", "+c0", "-F", "pcunPT"]`.
   Add a comment explaining that these arguments are what `LsofParser` is written against,
   so changing them requires changing the parser and its fixtures too.

**Verification**: `xcodebuild -project Squatter.xcodeproj -scheme Squatter -destination 'platform=macOS' test`
→ exit 0, 76 tests pass, including all seven above.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `xcodebuild -project Squatter.xcodeproj -scheme Squatter -configuration Debug build` exits 0
- [ ] `xcodebuild -project Squatter.xcodeproj -scheme Squatter -destination 'platform=macOS' test` exits 0 and reports 76 tests
- [ ] `SquatterTests/LsofRunnerTests.swift` exists and contains 7 `@Test` functions
      (`grep -c "@Test" SquatterTests/LsofRunnerTests.swift` → `7`)
- [ ] `grep -c "Process()" Squatter/Services/LsofRunner.swift` → `1`
- [ ] `grep -rn "/bin/sh" Squatter/` → no matches
- [ ] `git diff --stat -- Squatter/Services/PortScanner.swift SquatterTests/PortScannerTests.swift` → empty
- [ ] `grep -c "LsofRunnerTests" Squatter.xcodeproj/project.pbxproj` → at least `1`
      (proves the test file is actually compiled, not merely present on disk)
- [ ] `git diff -- Squatter.xcodeproj` changes **only** `LsofRunnerTests.swift` references —
      no build setting, bundle id, deployment target, entitlement, `ENABLE_APP_SANDBOX`,
      `ENABLE_HARDENED_RUNTIME` or `SWIFT_STRICT_CONCURRENCY` value may differ
- [ ] `grep -n "\.bytes" Squatter/Services/LsofRunner.swift` returns **only comment lines**
      (`//` or `///`) — no executable statement calls `.bytes` any more. *(Corrected
      2026-08-28: this criterion originally demanded a count of `0`, which contradicted
      step 2b's own mandated doc comment, since that comment names `handle.bytes` to explain
      what used to deadlock. The check is "the call is gone", not "the string is gone".)*
- [ ] `grep -c "DispatchQueue.global" Squatter/Services/LsofRunner.swift` → `1`
- [ ] Test 5 (`largeOutputDoesNotDeadlockTheDrain`) passes in under a second, rather than hanging
- [ ] `git status --porcelain` lists only `Squatter/Services/LsofRunner.swift`,
      `SquatterTests/LsofRunnerTests.swift`, `Squatter.xcodeproj/project.pbxproj`,
      `TRACKER.md`, `CHANGELOG.md` — nothing staged or committed
- [ ] `plans/README.md` status row for 002 updated

## STOP conditions

Stop and report back (do not improvise) if:

- The drift check shows `Squatter/Services/LsofRunner.swift` changed since `9c7eef2` and no
  longer matches the excerpt above.
- A `ProcessRunner` type already exists — the refactor has been done independently.
- Any of the 69 existing tests fails after step 2. Step 2 is behaviour-preserving by
  construction; a failure means the extraction changed semantics. **Do not edit an existing
  test to make it pass.**
- Test 5 (`largeOutputDoesNotDeadlockTheDrain`) still hangs **after** step 2b. Step 2b is
  the fix for exactly that hang, validated standalone at 128 KB, 256 KB and 4 MB. If it still
  hangs, the fix did not take or there is a second cause — report the observed behaviour and
  do not shrink the payload to make it pass.
- You need a `ScanError` case that does not exist. Adding one is plan 003's job.
- `xcodegen generate` changes anything in `Squatter.xcodeproj` beyond the new test file's
  references. That means the committed project had already drifted from `project.yml`, which
  is the owner's call to resolve, not yours. Report the exact diff.
- `/bin/dd`, `/bin/ls`, `/bin/echo` or `/usr/bin/true` is missing from the test machine
  (check with `ls -l` before writing test 5).

## Maintenance notes

- `ProcessRunner` is intentionally *not* `CommandRunning`. Only `LsofRunner` conforms, so
  the protocol keeps meaning "produces `lsof` output" and `PortScanner`'s injection point is
  unchanged. Do not add a conformance to make some future test shorter.
- The reused `ScanError.lsofNotFound` is a deliberate compromise, documented in the code.
  If the app ever gains a second subprocess (e.g. the `docker ps` integration sketched as P2
  in `PROJECT_SPEC.md`), that is the moment to give `ProcessRunner` its own error type and
  map it at the `LsofRunner` boundary — not before.
- A reviewer should confirm that `LsofRunner.run()` is now a one-line delegation and that
  the constants are still `static let`, not stored properties with defaults. The difference
  matters: stored properties with defaults would let a caller override the command.
- The byte-at-a-time `readToEnd` is gone as of step 2b, which also makes the old
  "it's only 1.2 KB, so the per-byte read costs nothing" note moot — the replacement is both
  correct and ~1000x faster on large payloads. Test 5 is now the regression test for it.
- **The audit got this wrong, and it is worth knowing why.** The original audit explicitly
  considered and rejected the per-byte read as a non-issue, and treated the concurrent drain
  as correct — both conclusions were drawn from reading the code and measuring real `lsof`
  output (~1.2 KB), which never approaches the 64 KB pipe buffer where the bug lives. Only
  writing a test with a deliberately oversized payload surfaced it. Worth remembering the
  next time a subprocess path "looks obviously fine".
