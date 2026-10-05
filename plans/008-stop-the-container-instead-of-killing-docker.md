# Plan 008: Offer "Stop Container" instead of killing Docker

> **Notion tracking — 2026-09-06:** Current task tracking is in Notion: [Squatter](https://app.notion.com/p/3d3cacb0997081acbbbbfc2bd0f0ddf8), [Tasks](https://app.notion.com/p/3d2cacb09970808d99b7f3c0c0a36f35). Any Linear URLs, IDs, statuses or refusals below are historical references. Resolve migrated IDs via `Linear ID` and verify `Project`; use the Notion task page for all new updates. This supersedes instructions below to create, query, update or close Linear issues. Follow the current repository tracking rule, including its owner-review requirements.

> **Executor instructions**: Follow this plan step by step. Run every verification
> command and confirm the expected result before moving to the next step. If anything
> in the "STOP conditions" section occurs, stop and report — do not improvise. When
> done, update the status row for this plan in `plans/README.md`.
>
> **Drift check (run first)**:
> `git diff --stat 947e97c..HEAD -- Squatter/ViewModels/PortListModel.swift Squatter/Views/PortRow.swift Squatter/Services/ProcessKiller.swift`
>
> **This plan requires plan 007 to have landed.** Confirm with
> `grep -n 'struct ContainerRef' Squatter/Model/Listener.swift` → one match, and
> `ls Squatter/Services/DockerProbe.swift` → the file exists. If either is missing,
> STOP — execute `plans/007-name-the-docker-container-behind-a-port.md` first.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: MED — this is a new destructive action against user infrastructure
- **Depends on**: `plans/007-name-the-docker-container-behind-a-port.md`
- **Category**: direction (new feature)
- **Planned at**: commit `947e97c`, 2026-08-29

## Why this matters

After plan 007 the row for a container-published port says `api-db-1` instead of
`com.docker.backend` — but the ✕ button on it still sends `SIGTERM` to Docker Desktop's
host proxy. That is the wrong action in the most literal sense: it does not stop the
container, it damages Docker's networking for every container at once, and the port comes
back the moment Docker recovers. The row now names one thing and acts on another.

`PROJECT_SPEC.md:73` calls for offering *"'Stop container' instead of kill"*. This plan
makes the row's destructive action match its label: on a row Squatter has identified as a
container, Kill Process and Force Kill are replaced by **Stop Container**, which runs
`docker stop` on that container's ID and nothing else.

Rows where Docker is involved but no container was identified (Docker not running, an
unrecognised proxy process) keep today's behaviour untouched — Squatter never guesses at a
destructive action.

## Current state

### The kill flow you are extending — `Squatter/ViewModels/PortListModel.swift:5-18`

```swift
/// Per-row progress of a kill request.
enum KillState: Equatable, Sendable {
    /// Kill was requested; waiting for the user to confirm before any signal is sent.
    case confirming
    /// Force Kill was requested from the menu; waiting for confirmation before SIGKILL.
    case confirmingForce
    /// SIGTERM sent; waiting up to the grace period for the process to exit.
    case terminating
    /// Still alive after the grace period — the UI offers Force Kill.
    case stillRunning
    /// SIGKILL sent; waiting for exit.
    case forcing
    case failed(String)
}
```

Every kill path in the model follows the same two-beat shape — **arm, then act** — added by
plan 001 after an owner decision that no kill happens without confirmation
(`PortListModel.swift:186-232`):

```swift
    /// Arms the confirmation. Nothing is signalled until `kill(_:)`.
    /// Only one row can be armed at a time — arming a new one cancels the previous.
    func requestKill(_ listener: Listener) {
        guard listener.isOwnedByCurrentUser, killStates[listener.id] == nil else { return }
        cancelAllKillConfirmations()
        killStates[listener.id] = .confirming
    }
...
    /// The two armed-but-unsignalled states. Anything else is a kill already in flight
    /// and must survive cancellation.
    private static func isConfirming(_ state: KillState?) -> Bool {
        state == .confirming || state == .confirmingForce
    }

    func kill(_ listener: Listener) async {
        guard listener.isOwnedByCurrentUser else { return }
        killStates[listener.id] = .terminating
        do {
            try killer.terminate(listener)
        } catch {
            killStates[listener.id] = .failed(error.localizedDescription)
            return
        }
        if await killer.waitForExit(of: listener, timeout: forceKillGrace) {
            killStates[listener.id] = nil
            await refresh()
        } else {
            killStates[listener.id] = .stillRunning
        }
    }
```

Your new states must slot into all four of these behaviours, which already exist and are
tested: `cancelAllKillConfirmations()` (Escape, and closing the popover), "arming a second
row cancels the first", "an armed prompt clears when the row disappears from a refresh", and
"a kill already in flight survives cancellation".

### The row's destructive affordances — `Squatter/Views/PortRow.swift`

Three places offer a kill, all switching or branching on the same state:

1. `trailing` (line 106+) — a `switch killState` that is **exhaustive with no `default`**.
   Adding a `KillState` case makes this file fail to compile until you handle it. That is
   deliberate (`rules/ios-swift.md`: *"`switch` over enums must be exhaustive without
   `default` where feasible, so new cases fail at compile time"*).
2. `hoverActions` (line 186+) — the ✕ chip:

```swift
            RowAction(systemImage: "xmark", tint: canKill ? .red : .secondary) {
                model.requestKill(listener)
            }
            .disabled(!canKill)
            .accessibilityLabel(Text("Kill \(listener.processName) on port \(String(listener.port))"))
```

3. `menuItems` (line 233+) — shared by the ⋯ button and the right-click menu:

```swift
        Button("Kill Process", systemImage: "xmark.circle", role: .destructive) {
            model.requestKill(listener)
        }
        .disabled(!canKill)
        Button("Force Kill", systemImage: "bolt.fill", role: .destructive) {
            model.requestForceKill(listener)
        }
        .disabled(!canKill)
```

Plus `.accessibilityAction(named: Text("Kill Process")) { model.requestKill(listener) }` at
line 60, and the ⌫ key path `PortListModel.killSelected()` (line 268).

### The service to model yours on — `Squatter/Services/ProcessKiller.swift`

`ProcessKiller` is a struct with injected function properties (`signal:`, `processName:`) so
tests never touch a real process — see `KillRecorder` in `SquatterTests/TestDoubles.swift`.
Errors are a typed `KillError` conforming to `LocalizedError`. Read that file before writing
`ContainerStopper`; match its shape.

### Conventions this plan must honor

- `rules/ux-writing.md`: **Title Case** for buttons and menu items ("Stop Container").
  *"The destructive verb is **Kill** — it matches developer vocabulary… Do not soften to
  'Stop' or 'End'."* That rule is about killing a **process**; stopping a container is a
  different operation with a different name in every Docker UI, and `PROJECT_SPEC.md:73`
  specifies "Stop container". Use **Stop Container** for containers and keep **Kill** for
  processes. Step 7 adds that carve-out to the rule file so the next agent does not
  "correct" it.
- Errors say **what failed + why + what to do next**, and never point at logs.
- Golden rule #7 — absolute path, fixed arguments, no shell. The container ID is the only
  variable argument in this app; step 1 validates it before it is ever passed to `Process`.
- **Do not commit, do not push, do not touch Linear.**

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Regenerate project (**required** after adding files) | `xcodegen generate` | project regenerated |
| Build | `xcodebuild -project Squatter.xcodeproj -scheme Squatter -configuration Debug build` | `** BUILD SUCCEEDED **` |
| Test | `xcodebuild -project Squatter.xcodeproj -scheme Squatter -destination 'platform=macOS' test` | `** TEST SUCCEEDED **` |

Baseline is whatever plan 007 left (≈93 tests). No previously-passing test may fail.

## Scope

**In scope**:
- `Squatter/Services/ContainerStopper.swift` (create)
- `Squatter/ViewModels/PortListModel.swift`
- `Squatter/Views/PortRow.swift`
- `SquatterTests/ContainerStopperTests.swift` (create)
- `SquatterTests/PortListModelTests.swift`, `SquatterTests/TestDoubles.swift`,
  `SquatterTests/SnapshotTests.swift`
- `Squatter.xcodeproj/project.pbxproj` (regenerated)
- `TRACKER.md`, `CHANGELOG.md`, `PROJECT_SPEC.md`, `rules/ux-writing.md`

**Out of scope**:
- `Squatter/Services/ProcessKiller.swift` — do not touch. Container stopping is a separate
  service; folding it into the killer would put a subprocess inside the type whose entire
  safety argument is "it only calls `kill(2)` after re-validating the PID".
- `Squatter/Services/DockerProbe.swift` — reuse `ProcessRunner` and
  `DockerProbe.findExecutable()`; do not change the probe's caching or parsing.
- `docker rm`, `docker kill`, `docker compose down`, restarting containers, or anything else
  that removes state. **Stop only.** A stopped container can be started again; a removed one
  cannot, and Squatter must never be the reason someone loses a database volume.
- Rows with `container == nil`, including `com.docker.backend` rows Squatter could not map.
  Their behaviour must be byte-for-byte what it is today.

## Steps

### Step 1: Create `ContainerStopper`

Create `Squatter/Services/ContainerStopper.swift`.

```swift
/// Why a container could not be stopped. Messages follow the "what / why / next" rule.
enum ContainerStopError: Error, Equatable, Sendable, LocalizedError {
    case dockerNotFound
    case invalidID
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .dockerNotFound:
            String(localized: "Couldn't find the docker command. Start Docker Desktop, or stop this container from your terminal.")
        case .invalidID:
            String(localized: "Couldn't stop this container: Squatter didn't recognise its ID. Refresh and try again.")
        case .failed(let reason):
            String(localized: "Couldn't stop this container. \(reason) Try `docker stop` in your terminal.")
        }
    }
}

/// Runs `docker stop` for one container. Separate from `ProcessKiller` on purpose: that type
/// only ever calls `kill(2)`, and this one only ever runs one fixed subprocess.
struct ContainerStopper: Sendable {
    /// `--time 5`: SIGTERM, then SIGKILL after five seconds. Docker's default is ten, which
    /// is a long time to watch a spinner.
    static func arguments(id: String) -> [String] { ["stop", "--time", "5", id] }
    /// Long enough to cover `--time 5` plus Docker's own overhead, well short of forever.
    static let timeout: Duration = .seconds(20)

    /// Only lowercase hex, 12–64 characters — the exact shape of a Docker container ID.
    /// The ID is the one argument in this app that comes from parsed output rather than a
    /// constant, so it is validated before it can reach `Process`.
    static func isValidID(_ id: String) -> Bool
}
```

`isValidID` must reject: empty, uppercase, anything with `-`, `/`, `.`, `;`, whitespace, a
leading `-` (which `docker` would read as a flag), and anything longer than 64 characters.
Implement it with `allSatisfy` over `"0123456789abcdef"`, plus the length check — do **not**
use `NSRegularExpression`.

Give the struct an injectable runner so tests spawn nothing:

```swift
    /// Builds the real runner from the discovered CLI path; injectable for tests.
    var makeRunner: @Sendable (String) -> (any CommandRunning)? = { id in ... }

    func stop(_ container: ContainerRef) async throws
```

`stop` must, in this order: validate the ID (`throw .invalidID`), find the CLI
(`DockerProbe.findExecutable()`, `throw .dockerNotFound` when nil), run it, and throw
`.failed(<trimmed stderr, or "docker exited with code N" when stderr is empty>)` on a
non-zero exit. Exit 0 returns normally.

**Verify**: `xcodegen generate`, then build → `** BUILD SUCCEEDED **`, then
`grep -n 'Process(' Squatter/Services/ContainerStopper.swift` → no matches.

### Step 2: Test `ContainerStopper` in isolation

Create `SquatterTests/ContainerStopperTests.swift`. Add to `SquatterTests/TestDoubles.swift`
a recorder that captures what would have been run (model it on the existing `KillRecorder`):

```swift
/// Records the argv a container stop would have used, and serves a scripted result.
final class StopRecorder: Sendable { ... }
```

Tests to write:

1. `validIDsAreAcceptedAndInvalidOnesRejected` — `isValidID` is true for a 12-char and a
   64-char lowercase hex string; false for `""`, `"ABCDEF123456"`, `"abc"`,
   `"--rm; rm -rf /"`, `"a b"`, and a 65-char string.
2. `stopBuildsTheExactArgv` — stopping a container with ID `aa11bb22cc33` runs
   `["stop", "--time", "5", "aa11bb22cc33"]` and nothing else.
3. `invalidIDNeverRunsAnything` — a `ContainerRef` with ID `"; rm -rf ~"` throws
   `.invalidID` and the recorder saw **zero** launches.
4. `nonZeroExitSurfacesStderr` — a scripted exit code 1 with stderr
   `Error response from daemon: No such container` throws `.failed`, and the message
   contains that text and the words "Try `docker stop`".
5. `missingDockerThrowsNotFound` — with the CLI lookup forced to `nil`, `.dockerNotFound`.

**Verify**: test command → `** TEST SUCCEEDED **`, five new tests.

### Step 3: Add the model states and intents

In `Squatter/ViewModels/PortListModel.swift`:

Add two cases to `KillState`, each with a doc comment matching the style of the others:

```swift
    /// Stop Container was requested; waiting for confirmation before `docker stop`.
    case confirmingStop
    /// `docker stop` is running.
    case stopping
```

Add `.confirmingStop` to `isConfirming` — it is an armed-but-unsignalled state, so Escape,
closing the popover, and arming another row must all clear it:

```swift
    private static func isConfirming(_ state: KillState?) -> Bool {
        state == .confirming || state == .confirmingForce || state == .confirmingStop
    }
```

Add the stopper as an injected dependency next to `killer`:

```swift
    @ObservationIgnored private let stopper: ContainerStopper
```
with `stopper: ContainerStopper = ContainerStopper()` in `init`, placed after `killer:`.

Add the arm/act pair, mirroring `requestKill`/`kill` exactly:

```swift
    /// Arms the Stop Container confirmation. Nothing runs until `stopContainer(_:)`.
    /// Only rows Squatter mapped to a container can be armed — never a bare process.
    func requestStopContainer(_ listener: Listener) {
        guard listener.container != nil, killStates[listener.id] == nil else { return }
        cancelAllKillConfirmations()
        killStates[listener.id] = .confirmingStop
    }

    func stopContainer(_ listener: Listener) async {
        guard let container = listener.container else { return }
        killStates[listener.id] = .stopping
        do {
            try await stopper.stop(container)
        } catch {
            killStates[listener.id] = .failed(error.localizedDescription)
            return
        }
        killStates[listener.id] = nil
        await refresh()
    }
```

Note the ownership guard is `container != nil`, **not** `isOwnedByCurrentUser` — the Docker
proxy process may well be owned by the user, but what authorises the action here is that
Squatter identified a container, not who owns the proxy.

Then close the two paths that would otherwise still send a signal to Docker's proxy:

- `requestKill` and `requestForceKill` gain `listener.container == nil` to their guard —
  a container row cannot arm a process kill at all, even if some future view forgets to
  branch.
- `killSelected()` (the ⌫ key) routes container rows to `requestStopContainer` instead:

```swift
    @discardableResult
    func killSelected() -> Bool {
        guard let listener = selectedListener, killStates[listener.id] == nil else { return false }
        if listener.container != nil {
            requestStopContainer(listener)
            return true
        }
        guard listener.isOwnedByCurrentUser else { return false }
        requestKill(listener)
        return true
    }
```

**Verify**: build → `** BUILD SUCCEEDED **`. It will fail first with a non-exhaustive
`switch` error in `PortRow.swift` — that is the compiler doing its job; step 4 fixes it.

### Step 4: Make the row offer Stop Container

In `Squatter/Views/PortRow.swift`:

- Add `private var isContainer: Bool { listener.container != nil }`.
- `menuItems`: when `isContainer`, replace the two kill buttons with one:

```swift
        Button("Stop Container", systemImage: "stop.circle", role: .destructive) {
            model.requestStopContainer(listener)
        }
```
  Keep Open in Browser, the three Copy items, and the Ignore items exactly as they are. When
  `!isContainer`, the menu is unchanged from today.
- `hoverActions`: when `isContainer`, the ✕ chip becomes
  `RowAction(systemImage: "stop.fill", tint: .red) { model.requestStopContainer(listener) }`
  with accessibility label
  `Text("Stop container \(listener.displayName) on port \(String(listener.port))")` and help
  `Text("Stop the Docker container \(listener.displayName)")` — sentence case for both.
- `confirmationPrompt`: add `case .confirmingStop: Text("Stop this container?")`.
- `trailing`: add the two new cases.
  - `.confirmingStop` — Cancel + a prominent red `Button("Stop Container", role: .destructive)`
    running `Task { await model.stopContainer(listener) }`, `.fixedSize()`, matching the
    `.confirming` case's layout exactly (that `.fixedSize()` and layout priority exist
    because long names once squeezed these buttons into ellipses — keep them).
  - `.stopping` — `progress(Text("Stopping…"))`, real ellipsis character.
- `ledColor`: `.confirmingStop` is `.red` (armed, like the other confirmations); `.stopping`
  is `.orange` (in flight, like `.terminating`).
- The accessibility action at line 60: when `isContainer`, name it `Text("Stop Container")`
  and call `model.requestStopContainer(listener)`.

**Verify**: build → `** BUILD SUCCEEDED **`, and
`grep -n 'default:' Squatter/Views/PortRow.swift` → only the pre-existing one inside
`confirmationPrompt` (the `switch killState` in `trailing` must stay exhaustive without a
`default`).

### Step 5: Model tests for the new path

In `SquatterTests/PortListModelTests.swift`, add (patterns: the existing
`killPathsArmAConfirmationInsteadOfSignalling`, `confirmingSendsSigtermAndEscapeCancelsEverything`,
`armingASecondRowCancelsTheFirst`):

1. `stopContainerArmsAConfirmationInsteadOfRunningDocker` — `requestStopContainer` sets
   `.confirmingStop` and the stop recorder saw zero launches.
2. `confirmedStopRunsDockerStopOnceAndRefreshes` — after `await stopContainer(listener)` the
   recorder saw exactly one stop for that container ID, the row's state is `nil`, and a
   refresh happened.
3. `containerRowsCannotArmAProcessKill` — `requestKill` and `requestForceKill` on a
   container row leave `killState` `nil` and signal nothing.
4. `nonContainerRowsCannotArmAStop` — `requestStopContainer` on the plain `node` row does
   nothing.
5. `escapeCancelsAnArmedStop` — `cancelAllKillConfirmations()` clears `.confirmingStop` but
   leaves a `.stopping` row alone.
6. `stopFailureSurfacesTheMessageAndIsDismissable` — a scripted failure lands in
   `.failed`, `dismissKillError(for:)` clears it.
7. `deleteKeyArmsStopOnAContainerRow` — `killSelected()` on a selected container row arms
   `.confirmingStop`, not `.confirming`.

**Verify**: test command → `** TEST SUCCEEDED **`, ≥ 7 new tests here.

### Step 6: Snapshot the new states

In `SquatterTests/SnapshotTests.swift`, reuse the `list-docker` model added by plan 007:
arm a stop on the container row and snapshot as `"list-confirm-stop"`; add its URL to the
size-check loop. Open the PNG and confirm the Cancel / Stop Container buttons are fully
readable and not truncated — that check is why these snapshots exist.

**Verify**: test command → `** TEST SUCCEEDED **`; PNG inspected by eye.

### Step 7: Docs

- `rules/ux-writing.md` — under **Buttons & menu items**, after the "destructive verb is
  Kill" line, add the carve-out: *"The exception is Docker containers, which are stopped,
  not killed: the button is **Stop Container** and the in-flight state is 'Stopping…'.
  Killing Docker's proxy process is a different, wrong action."*
- `PROJECT_SPEC.md:73` — tick the remaining half of the Docker bullet.
- `TRACKER.md` — dated entry: what shipped, that `requestKill` now refuses container rows,
  and that `docker rm` was deliberately not offered.
- `CHANGELOG.md` `[Unreleased]` → **Added**, e.g. *"Ports published by Docker now offer Stop
  Container, which stops that container instead of killing Docker itself."*

**Verify**: `git status --short` lists only in-scope files.

## Done criteria

ALL must hold:

- [ ] `xcodegen generate` run; `project.pbxproj` shows in `git status`
- [ ] Build → `** BUILD SUCCEEDED **`; test → `** TEST SUCCEEDED **`, ≥ 12 new tests, zero failures
- [ ] `grep -n 'default:' Squatter/Views/PortRow.swift` → the `switch killState` in
      `trailing` has no `default:`
- [ ] `grep -n 'container == nil' Squatter/ViewModels/PortListModel.swift` → present in both
      `requestKill` and `requestForceKill`
- [ ] `grep -rn 'docker rm\|"rm"\|--force\|-f"' Squatter/Services/ContainerStopper.swift` → no matches
- [ ] `grep -n 'isValidID' Squatter/Services/ContainerStopper.swift` → called before any
      runner is constructed
- [ ] The `list-confirm-stop` snapshot shows both buttons in full
- [ ] `TRACKER.md`, `CHANGELOG.md`, `PROJECT_SPEC.md`, `rules/ux-writing.md` updated
- [ ] Nothing committed, nothing pushed, no Linear issue touched
- [ ] `plans/README.md` status row for 008 updated

## STOP conditions

Stop and report if:

- Plan 007 has not landed (`ContainerRef` or `DockerProbe.swift` missing).
- Making `KillState` exhaustive again requires a `default:` — it does not; handle both new
  cases explicitly.
- A test proves a container row can still reach `ProcessKiller`. That is the one outcome
  this plan exists to prevent; report it rather than patching the view.
- You are tempted to add `docker rm`, `docker kill`, `docker restart`, or a "stop all"
  action. All are out of scope and one of them destroys data.
- `docker stop` needs an environment variable beyond `HOME` to reach the daemon on your test
  machine. Report what it needs; do not start reading the user's shell configuration.

## Maintenance notes

- **Unverified against a real daemon**, exactly like plan 007 — no Docker on the owner's
  machine as of 2026-08-29. The owner must stop a real container through the UI once before
  this ships, and confirm the row disappears within one refresh tick afterwards.
- `ContainerStopper.isValidID` is the only input validation in the app that stands between
  parsed output and an argv element. A reviewer should read it first and try to think of a
  string that passes it and still means something to `docker`.
- If `DockerProbe` ever learns to talk to the daemon's unix socket directly instead of
  shelling out to the CLI, this service should follow — `POST /containers/{id}/stop` is the
  same operation without the subprocess.
- Deliberately deferred: starting a stopped container (Squatter only lists things that are
  listening, so a stopped container has no row to act on), and Docker Compose project
  grouping.
