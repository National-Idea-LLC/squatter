# Plan 003: Stop a stuck `lsof` from wedging the app forever

> **Notion tracking — 2026-09-06:** Current task tracking is in Notion: [Squatter](https://app.notion.com/p/3d3cacb0997081acbbbbfc2bd0f0ddf8), [Tasks](https://app.notion.com/p/3d2cacb09970808d99b7f3c0c0a36f35). Any Linear URLs, IDs, statuses or refusals below are historical references. Resolve migrated IDs via `Linear ID` and verify `Project`; use the Notion task page for all new updates. This supersedes instructions below to create, query, update or close Linear issues. Follow the current repository tracking rule, including its owner-review requirements.

> **Executor instructions**: Follow this plan step by step. Run every verification
> command and confirm the expected result before moving to the next step. If anything
> in the "STOP conditions" section occurs, stop and report — do not improvise. When
> done, update the status row for this plan in `plans/README.md`.
>
> **Drift check (run first)**:
> `git diff --stat 9c7eef2..HEAD -- Squatter/Services/LsofRunner.swift Squatter/Services/PortScanner.swift`
> **This plan assumes plan 002 has already landed** and `ProcessRunner` exists in
> `Squatter/Services/LsofRunner.swift`. If it does not, STOP — execute plan 002 first.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW
- **Depends on**: `plans/002-test-the-lsof-subprocess.md` (needs the `ProcessRunner` seam, and its tests are the pattern for this one)
- **Category**: bug
- **Planned at**: commit `9c7eef2`, 2026-08-28

## Why this matters

There is no timeout anywhere between the app and `lsof`. If the child process never exits —
`lsof` blocking on a stalled network mount is its best-known failure mode, and the reason
`lsof` ships a `-b` "avoid blocking kernel calls" flag at all — the failure is permanent and
total:

1. `ProcessRunner.run()` waits for EOF on the pipes, which never comes.
2. `PortScanner.scan()` never returns, so its `defer { inFlight = nil }` never runs. Every
   later `scan()` takes the `if let inFlight { return try await inFlight.value }` branch and
   joins the same dead task — including the one behind the Refresh button.
3. `PortListModel.refresh()` never completes, so `isRefreshing` stays `true` and the polling
   loop is parked inside its `await refresh()` forever.

The user sees a permanent spinner. Refresh does nothing. Changing the refresh interval does
nothing. Reopening the popover does nothing. The only recovery is quitting the app — and
because the failure is silent, nothing tells them that is what is needed.

After this plan, a scan that overruns its budget kills the child, surfaces a plain-language
error with a Retry button (the UI for that already exists — `PortListView.errorBanner`), and
leaves the scanner able to try again.

## Current state

**Precondition**: plan 002 has landed. `Squatter/Services/LsofRunner.swift` contains a
`ProcessRunner` struct with `executablePath` and `arguments` stored properties, and
`LsofRunner` is a thin wrapper holding the fixed constants. The body you are modifying looks
like this (from plan 002, step 1):

```swift
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

        // Drain both pipes on separate threads so a large listing can't fill a pipe and
        // stall the child. See readToEnd — doing this with FileHandle.bytes deadlocks.
        async let stdout = Self.readToEnd(stdoutPipe.fileHandleForReading)
        async let stderr = Self.readToEnd(stderrPipe.fileHandleForReading)
        let (out, err) = try await (stdout, stderr)
        await exited.value

        return CommandResult(stdout: out, stderr: err, exitCode: process.terminationStatus)
    }

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
}
```

> **Updated 2026-08-28**: `readToEnd` above reflects the drain fix that landed with plan 002.
> An earlier revision of this plan quoted the old `for try await byte in handle.bytes`
> version, which deadlocked on any child writing more than 64 KB to stdout. Your watchdog
> still works the same way: killing the child closes its pipe write ends, the blocking reads
> return EOF, and control reaches the `throw`.

### The error type you will extend — `Squatter/Services/LsofRunner.swift:15-34`

```swift
/// Why a scan could not produce a listener list. Messages follow the "what / why / next" rule.
enum ScanError: Error, Equatable, Sendable, LocalizedError {
    case lsofNotFound(path: String)
    case launchFailed(String)
    case nonZeroExit(code: Int32, stderr: String)
    case outputNotUTF8

    var errorDescription: String? {
        switch self {
        case .lsofNotFound(let path):
            String(localized: "Couldn't find lsof at \(path). Squatter needs the system lsof tool to list ports.")
        case .launchFailed(let reason):
            String(localized: "Couldn't start lsof: \(reason). Try refreshing.")
        case .nonZeroExit(let code, let stderr):
            String(localized: "lsof exited with code \(code). \(stderr.isEmpty ? "" : stderr) Try refreshing.")
        case .outputNotUTF8:
            String(localized: "lsof returned output Squatter couldn't read. Try refreshing.")
        }
    }
}
```

### Where a thrown error lands (no changes needed here — context only)

`PortScanner.scan()` at `Squatter/Services/PortScanner.swift:23-34` clears `inFlight` via
`defer` as soon as `run()` throws, so the next scan launches a fresh process.
`PortListModel.refresh()` catches it into `lastError`, and `PortListView` already renders
either a full-screen error state with a Retry button or, when a previous list is still on
screen, a red banner with Retry. **You do not need to touch the model or any view.**

### Conventions you must match

Inlined from `AGENTS.md` and `rules/ux-writing.md` — you have not read them:

- **Error copy rule**: errors say *what failed, why, and what to do next*. Sentence case.
  Look at the four existing `errorDescription` strings above and match their register — they
  all end in an instruction like "Try refreshing."
- **Golden rule #7**: no shell, ever, in production code. Signals are sent with `kill(2)`.
  `ProcessKiller.swift` already does this and is the exemplar: it does `import Darwin` and
  calls `Darwin.kill(pid, sig)` with an explicit module qualifier. Copy that idiom.
- **Swift 6, strict concurrency complete, warnings are errors.** `Process` is `Sendable` on
  this platform (the existing `exited` Task already captures it), so capturing it in another
  task is fine.
- **Tests use Swift Testing** (`@Test`, `#expect`), never XCTest.
- **No third-party dependencies.** `Synchronization` (for `Mutex`) is part of the Swift
  standard library on macOS 15+ and is already used in `SquatterTests/TestDoubles.swift`.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Build | `xcodebuild -project Squatter.xcodeproj -scheme Squatter -configuration Debug build` | exit 0, no warnings |
| Test | `xcodebuild -project Squatter.xcodeproj -scheme Squatter -destination 'platform=macOS' test` | exit 0; **76 tests** before your changes, **79** after |

## Scope

**In scope**:
- `Squatter/Services/LsofRunner.swift`
- `SquatterTests/LsofRunnerTests.swift` (created by plan 002; you append to it)
- `TRACKER.md`, `CHANGELOG.md` (step 5)

**Out of scope** (do NOT touch):
- `Squatter/Services/PortScanner.swift` — its `defer { inFlight = nil }` already does the
  right thing once `run()` throws. Adding a second timeout layer there would double-count
  the budget.
- `Squatter/ViewModels/PortListModel.swift` and every view — the error path they need
  already exists and is already tested (`failedRefreshKeepsLastListAndReportsError`).
- `Squatter/Services/ProcessKiller.swift` — unrelated; it signals *other people's*
  processes, this plan signals our own child.
- The `readToEnd` implementation — plan 002 already replaced it with a per-pipe blocking
  read on `DispatchQueue.global()`. Leave it exactly as it is.

## Git workflow

**Do not commit anything.** This repo gates commits behind owner approval
(`rules/core-workflow.md`). Leave changes in the working tree and report. Do not `git add`,
commit, push, or open a PR. Do not update Linear — note in your report that `TRACKER.md`
and `CHANGELOG.md` changed and the owner needs to mirror it.

## Steps

### Step 1: Add the error case

In `Squatter/Services/LsofRunner.swift`, add `case timedOut` to `ScanError` after
`case outputNotUTF8`, and its message to `errorDescription`:

```swift
    case outputNotUTF8
    /// The child never exited within its budget and was killed.
    case timedOut
```

```swift
        case .timedOut:
            String(localized: "lsof didn't respond and was stopped. A stalled network or disk mount can cause this. Try refreshing.")
```

**Verify**: `xcodebuild -project Squatter.xcodeproj -scheme Squatter -configuration Debug build`
→ exit 0. `ScanError` is switched over exhaustively only inside its own `errorDescription`,
so nothing else should break.

### Step 2: Give `ProcessRunner` a timeout

At the top of `Squatter/Services/LsofRunner.swift`, add the two imports the watchdog needs
next to the existing `import Foundation`:

```swift
import Darwin
import Foundation
import Synchronization
```

Add a stored `timeout` property and a default to `ProcessRunner`:

```swift
struct ProcessRunner: Sendable {
    /// Generous next to a measured ~40 ms scan: this is a deadlock backstop, not a
    /// performance budget, and must never fire on a merely busy machine.
    static let defaultTimeout: Duration = .seconds(10)

    let executablePath: String
    let arguments: [String]
    var timeout: Duration = ProcessRunner.defaultTimeout
```

### Step 3: Add the watchdog

In `ProcessRunner.run()`, insert the watchdog immediately **after** the `do { try process.run() }
catch { ... }` block and **before** the `async let stdout` drain lines:

```swift
        // Nothing else bounds this call: if the child never exits, the drains below never
        // reach EOF, `PortScanner.inFlight` is never cleared, and every later scan — Refresh
        // included — joins the same dead task. Kill the child so the pipes close.
        let timedOut = Mutex(false)
        let watchdog = Task {
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, process.isRunning else { return }
            timedOut.withLock { $0 = true }
            process.terminate()
            try? await Task.sleep(for: .milliseconds(500))
            if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
        }
        defer { watchdog.cancel() }
```

Then replace the `return` at the end of `run()` so a timed-out run reports itself instead of
returning a truncated result:

```swift
        async let stdout = Self.readToEnd(stdoutPipe.fileHandleForReading)
        async let stderr = Self.readToEnd(stderrPipe.fileHandleForReading)
        let (out, err) = try await (stdout, stderr)
        await exited.value

        if timedOut.withLock({ $0 }) { throw ScanError.timedOut }
        return CommandResult(stdout: out, stderr: err, exitCode: process.terminationStatus)
```

Notes on why this shape:
- `try?` on the watchdog's sleep swallows the `CancellationError` raised by
  `watchdog.cancel()` on the happy path; the `guard !Task.isCancelled` immediately after is
  what actually stops it from signalling a process that already finished.
- `process.terminate()` sends SIGTERM; the 500 ms escalation to SIGKILL handles a child that
  ignores it. Once the child is dead its pipe write ends close, the drains hit EOF, and
  control reaches the `throw`.
- Do **not** move the `throw` above `await exited.value` — `process.terminationStatus` traps
  if read before the process has exited, and skipping the await would leave the drains
  unfinished.

**Verify**: `xcodebuild -project Squatter.xcodeproj -scheme Squatter -destination 'platform=macOS' test`
→ exit 0, **76 tests** still pass. The default 10 s timeout must not fire for any existing
test, including `realLsofRunsAndProducesFieldOutput`.

### Step 4: Write the tests

Append three tests to `SquatterTests/LsofRunnerTests.swift`. See "Test plan" below.

**Verify**: `xcodebuild -project Squatter.xcodeproj -scheme Squatter -destination 'platform=macOS' test`
→ exit 0, **79 tests** pass. The whole suite should still finish in well under a minute — if
it grows by ~5 seconds, your timeout test is waiting on the real sleep instead of the
watchdog, which means the watchdog is not firing.

### Step 5: Update the tracking docs

`TRACKER.md` — add at the **top** of the "Dev changelog" list:

```
- **2026-08-28** — Bounded the `lsof` subprocess: `ProcessRunner` now runs a 10-second watchdog that SIGTERMs (then SIGKILLs) a child that hasn't exited and reports `ScanError.timedOut`. Previously a child that never exited left the drains waiting on EOF forever, so `PortScanner.inFlight` was never cleared and every later scan — Refresh included — joined the same dead task, wedging the app until quit. 3 tests, 79 total.
```

`CHANGELOG.md` — one bullet under `## [Unreleased]` → `### Fixed`, user-facing language only:

```
- If the system tool Squatter uses to read ports ever stops responding, the list now shows an error you can retry instead of spinning forever.
```

**Verify**: `grep -c "timedOut" TRACKER.md` → `1`; `grep -n "spinning forever" CHANGELOG.md` → one match under `### Fixed`.

## Test plan

Append to `SquatterTests/LsofRunnerTests.swift`, matching the structure of the tests plan 002
put there. Add `import Testing`-adjacent imports only if missing.

1. `aStuckChildIsKilledAndReportedAsTimedOut()` — **the regression test.**

```swift
    @Test func aStuckChildIsKilledAndReportedAsTimedOut() async {
        let runner = ProcessRunner(executablePath: "/bin/sleep", arguments: ["5"], timeout: .milliseconds(200))
        let clock = ContinuousClock()
        let started = clock.now
        await #expect(throws: ScanError.timedOut) { try await runner.run() }
        // The child sleeps for 5s. Returning early is the proof it was actually killed:
        // had it survived, its pipes would still be open and `run()` would still be draining.
        #expect(clock.now - started < .seconds(2))
    }
```

2. `aFastCommandIsUnaffectedByAGenerousTimeout()` — guards against the watchdog firing on the
   happy path. `ProcessRunner(executablePath: "/bin/echo", arguments: ["ok"], timeout: .seconds(5))`
   → no throw, `exitCode == 0`, stdout decodes to `"ok\n"`.

3. `timeoutErrorSaysWhatWhyAndNext()` — matches the existing convention in
   `SquatterTests/ProcessKillerTests.swift` (`errorMessagesSayWhatWhyAndNext`). Assert
   `ScanError.timedOut.errorDescription` is non-nil and contains both `"didn't respond"` and
   `"Try refreshing"`.

**Verification**: `xcodebuild -project Squatter.xcodeproj -scheme Squatter -destination 'platform=macOS' test`
→ exit 0, 79 tests pass.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `xcodebuild -project Squatter.xcodeproj -scheme Squatter -configuration Debug build` exits 0
- [ ] `xcodebuild -project Squatter.xcodeproj -scheme Squatter -destination 'platform=macOS' test` exits 0 and reports 79 tests
- [ ] `grep -c "@Test" SquatterTests/LsofRunnerTests.swift` → `10` (7 from plan 002 + 3 here)
- [ ] `grep -n "defaultTimeout" Squatter/Services/LsofRunner.swift` → the constant is `.seconds(10)`
- [ ] `grep -n "Darwin.kill" Squatter/Services/LsofRunner.swift` → exactly one match, inside the watchdog
- [ ] `git diff --stat -- Squatter/Services/PortScanner.swift Squatter/ViewModels/PortListModel.swift` → empty
- [ ] `git status --porcelain` lists only `Squatter/Services/LsofRunner.swift`,
      `SquatterTests/LsofRunnerTests.swift`, `TRACKER.md`, `CHANGELOG.md` — nothing staged or committed
- [ ] `plans/README.md` status row for 003 updated

## STOP conditions

Stop and report back (do not improvise) if:

- `ProcessRunner` does not exist in `Squatter/Services/LsofRunner.swift` — plan 002 has not
  landed. Do not inline a timeout into `LsofRunner` instead; there would be no way to test it.
- The build rejects capturing `process` in the watchdog `Task` with a `Sendable` error. That
  would mean `Process` is not `Sendable` on this toolchain, which contradicts the existing
  `exited` task — report it rather than adding `@unchecked Sendable` or `nonisolated(unsafe)`.
- Test 1 takes longer than ~2 seconds or hangs. That means the watchdog is not killing the
  child, and the timeout would not actually rescue the app. Report the observed behaviour;
  do not "fix" it by loosening the elapsed-time assertion.
- Any of the 76 pre-existing tests fails. In particular, if
  `realLsofRunsAndProducesFieldOutput` starts throwing `.timedOut`, the default budget is
  wrong for this machine — report the real duration rather than raising the constant.

## Maintenance notes

- **Known remaining gap, accepted deliberately**: this bounds the *common* hang, where the
  child is killable. A process wedged in an uninterruptible kernel wait ignores SIGKILL too;
  its pipe write ends stay open and `run()` would still not return. Closing that hole means
  abandoning the drain tasks rather than awaiting them (make them unstructured `Task`s and
  return without joining), which leaks two tasks per stuck scan. That trade was not worth
  making for a failure mode nobody has hit; revisit only if a real hang is reported.
- The watchdog and `PortListModel`'s refresh interval are independent budgets. If the refresh
  interval is ever allowed above 10 seconds (`Preferences.refreshInterval` currently clamps to
  60), a scan could still be running when the next tick fires — `PortScanner`'s in-flight
  coalescing already handles that, but a reviewer should confirm it stays true.
- A reviewer should check that `throw ScanError.timedOut` sits *after* `await exited.value`.
  Reading `terminationStatus` before the process exits traps.
- `ScanError.timedOut` deliberately carries no duration. Adding an associated value would put
  a "0 seconds" in the message for the sub-second timeouts the tests use, for no user benefit.
