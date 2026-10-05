# Plan 007: Show which Docker container owns a published port

> **Notion tracking — 2026-09-06:** Current task tracking is in Notion: [Squatter](https://app.notion.com/p/3d3cacb0997081acbbbbfc2bd0f0ddf8), [Tasks](https://app.notion.com/p/3d2cacb09970808d99b7f3c0c0a36f35). Any Linear URLs, IDs, statuses or refusals below are historical references. Resolve migrated IDs via `Linear ID` and verify `Project`; use the Notion task page for all new updates. This supersedes instructions below to create, query, update or close Linear issues. Follow the current repository tracking rule, including its owner-review requirements.

> **Executor instructions**: Follow this plan step by step. Run every verification
> command and confirm the expected result before moving to the next step. If anything
> in the "STOP conditions" section occurs, stop and report — do not improvise. When
> done, update the status row for this plan in `plans/README.md`.
>
> **Drift check (run first)**:
> `git diff --stat 947e97c..HEAD -- Squatter/Model/Listener.swift Squatter/Services/LsofRunner.swift Squatter/Services/PortScanner.swift Squatter/ViewModels/PortListModel.swift Squatter/Views/PortRow.swift Squatter/Model/Preferences.swift`
> If any of those changed since this plan was written, compare the "Current state"
> excerpts below against the live code before proceeding; on a mismatch, STOP.

## Status

- **Priority**: P2 (spec P2 feature, owner-requested 2026-08-29)
- **Effort**: L
- **Risk**: MED — adds a second subprocess to a one-subprocess app
- **Depends on**: none
- **Blocks**: `plans/008-stop-the-container-instead-of-killing-docker.md`
- **Category**: direction (new feature)
- **Planned at**: commit `947e97c`, 2026-08-29

## Why this matters

Every port published by a Docker container shows up in Squatter as one row owned by
`com.docker.backend` (Docker Desktop's host-side proxy). Five containers publishing five
ports produce five identical-looking rows that all say `com.docker.backend`, and the user
cannot tell which is Postgres and which is the API. Worse, the ✕ button on those rows is
armed and enabled: killing `com.docker.backend` does not free the port in any useful sense —
it takes down Docker Desktop's networking and every container with it.

`PROJECT_SPEC.md:73` lists this as P2: *"annotate ports published by Docker containers
(`docker ps --format json`) and offer 'Stop container' instead of kill."* This plan does the
first half only — **read-only annotation**. The row learns to say `api-db-1` (`postgres:16`)
instead of `com.docker.backend`. Nothing about killing changes; plan 008 does that, and
keeping the two apart means the labelling can ship and be lived with before anything gains
the power to stop a container.

After this plan: a container-published port shows the container's name and image, and
Squatter still spawns zero extra processes on a machine that has no Docker CLI installed.

## Current state

### The files you will touch, and their role

- `Squatter/Model/Listener.swift` (17 lines) — the value type for one listening socket.
  Has no notion of containers.
- `Squatter/Services/LsofRunner.swift` (138 lines) — contains **two** types: the generic
  `ProcessRunner` (absolute path + fixed argv + watchdog + pipe drain) and `LsofRunner`,
  the thin wrapper that supplies the `lsof` constants. You will reuse `ProcessRunner`.
- `Squatter/Services/PortScanner.swift` (59 lines) — the actor that runs `lsof` and turns
  the output into `[Listener]`. This is where annotation gets merged in.
- `Squatter/Model/Preferences.swift` (61 lines) — `DefaultsKeys` + typed `UserDefaults`.
- `Squatter/ViewModels/PortListModel.swift` (343 lines) — `@MainActor @Observable`; the
  only thing views bind to.
- `Squatter/Views/PortRow.swift` (308 lines) — one row.
- `Squatter/Services/DockerProbe.swift` — **you create this.**
- `SquatterTests/DockerProbeTests.swift` — **you create this.**
- `SquatterTests/Fixtures/docker-ps-sample.txt` — **you create this.**

### `Listener` today — `Squatter/Model/Listener.swift`, whole file

```swift
import Foundation

/// One listening TCP socket, collapsed across address families.
/// Identity is `(pid, port)`; IPv4/IPv6 rows for the same pair merge into one `Listener`.
struct Listener: Identifiable, Hashable, Sendable {
    let port: UInt16
    let pid: pid_t
    let processName: String
    let user: String
    let addresses: Set<String>
    let isOwnedByCurrentUser: Bool

    var id: String { "\(pid):\(port)" }

    /// `http://localhost:<port>` — what "Open" and "Copy URL" act on.
    var localURLString: String { "http://localhost:\(port)" }
}
```

`Listener` is constructed with its **memberwise initializer** in three places outside the
parser (`SquatterTests/TestDoubles.swift:38`, `SquatterTests/SnapshotTests.swift`, and
`Squatter/Services/LsofParser.swift`). Adding a `let` property with an inline default would
*remove* it from the memberwise initializer, so step 1 writes an explicit `init` with a
defaulted `container:` parameter. That keeps every existing call site compiling untouched.

### `ProcessRunner` today — `Squatter/Services/LsofRunner.swift:52-70` (excerpt)

```swift
struct ProcessRunner: Sendable {
    /// Generous next to a measured ~40 ms scan: this is a deadlock backstop, not a
    /// performance budget, and must never fire on a merely busy machine.
    static let defaultTimeout: Duration = .seconds(10)

    let executablePath: String
    let arguments: [String]
    var timeout: Duration = ProcessRunner.defaultTimeout

    func run() async throws -> CommandResult {
        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            throw ScanError.lsofNotFound(path: executablePath)
        }

        let process = Process()
        process.executableURL = URL(filePath: executablePath)
        process.arguments = arguments
        process.environment = [:]
```

Note `process.environment = [:]` — hardcoded. The `docker` CLI needs `HOME` to find
`~/.docker/config.json` and its context, so step 2 adds an `environment` property.

### `PortScanner.scan()` today — `Squatter/Services/PortScanner.swift:29-40`

```swift
    func scan() async throws -> [Listener] {
        if let inFlight {
            return try await inFlight.value
        }
        let task = Task { [runner, currentUID, userName] in
            let result = try await runner.run()
            return try Self.listeners(from: result, currentUID: currentUID, userName: userName)
        }
        inFlight = task
        defer { inFlight = nil }
        return try await task.value
    }
```

### `Preferences` today — the pattern to copy — `Squatter/Model/Preferences.swift:4-10, 44-58`

```swift
enum DefaultsKeys {
    static let refreshInterval = "squatter.refreshInterval"
    static let showCountInMenuBar = "squatter.showCountInMenuBar"
    static let ignoredPorts = "squatter.ignoredPorts"
    static let ignoredProcessNames = "squatter.ignoredProcessNames"
    static let sortOrder = "squatter.sortOrder"
}
...
    var showCountInMenuBar: Bool {
        get { defaults.bool(forKey: DefaultsKeys.showCountInMenuBar) }
        nonmutating set { defaults.set(newValue, forKey: DefaultsKeys.showCountInMenuBar) }
    }
```

`defaults.bool(forKey:)` returns `false` for an unset key. The new preference defaults to
**on**, so it must check `object(forKey:)` for nil rather than reading `bool` directly.

### `PortRow` title and caption today — `Squatter/Views/PortRow.swift:62-88` (excerpt)

```swift
    private var details: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(listener.processName)
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .foregroundStyle(isIgnored ? .secondary : .primary)
            if let confirmationPrompt {
                confirmationPrompt
                    .font(.caption2)
                    .foregroundStyle(.red)
            } else {
                HStack(spacing: 6) {
                    Text(verbatim: "PID \(listener.pid)")
                        .monospacedDigit()
                    ForEach(listener.addresses.sorted(), id: \.self) { address in
                        AddressChip(address: address)
                    }
                    Spacer(minLength: 0)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
    }
```

### Conventions this plan must honor (from `AGENTS.md` and `rules/`)

Quoted, because you have not read those files:

- **Golden rule #7**: *"Never spawn a shell. `lsof` is invoked by absolute path with fixed
  arguments via `Process`."* Your `docker` invocation must follow the same discipline:
  an absolute path chosen from a **fixed allowlist**, arguments as separate argv elements,
  no shell, no `PATH` lookup, no string interpolation into a command line. Step 9 amends
  `AGENTS.md` so the rule states the new reality.
- **Golden rule #6**: *"Stay minimal. No third-party packages… no telemetry or network
  calls."* `docker ps` talks to a local daemon over a unix socket; it is not a network call
  and no data leaves the machine. Say so in the code comment.
- `rules/ios-swift.md`: *"All user-facing strings go through `String(localized:)` … no bare
  literals in views"*; *"Swift 6 strict concurrency on; no `@unchecked Sendable`, no
  `DispatchQueue`"* (the one existing `DispatchQueue` in `ProcessRunner.readToEnd` is a
  documented exception — do not add another); *"`switch` over enums must be exhaustive
  **without** `default` where feasible"*; *"Use semantic/system colors and system fonts";
  *"SF Symbols for all buttons/menu/context-menu items"*.
- `rules/ux-writing.md`: **Sentence case** for descriptions, settings labels, tooltips and
  accessibility labels; **Title Case** for buttons and menu items.
- `rules/core-workflow.md`: update `TRACKER.md` on every meaningful change, and
  `CHANGELOG.md` under `[Unreleased]` when a user would notice. This one is user-visible,
  so both.
- **Do not commit and do not push.** Commits are gated behind owner approval. Leave the
  work in the working tree and report.
- **Keep Notion current** under `rules/issue-tracker-status.md`; leave tasks `In progress` and report ready for review until owner sign-off.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Regenerate project (**required** after adding files) | `xcodegen generate` | `Created project at .../Squatter.xcodeproj` |
| Build | `xcodebuild -project Squatter.xcodeproj -scheme Squatter -configuration Debug build` | `** BUILD SUCCEEDED **` |
| Test | `xcodebuild -project Squatter.xcodeproj -scheme Squatter -destination 'platform=macOS' test` | `** TEST SUCCEEDED **` |

**Baseline: 84 tests in 9 suites pass at commit `947e97c`.** This plan adds tests; the final
count must be higher, and no previously-passing test may fail.

**`xcodegen generate` is not optional.** `Squatter.xcodeproj` enumerates every source file
individually. A new `.swift` file that is not registered compiles into nothing and its tests
silently do not run — this exact mistake happened during plan 002 and the suite stayed at 69
while appearing green. Run `xcodegen generate` immediately after creating each new file, and
expect `Squatter.xcodeproj/project.pbxproj` to appear in `git status`. That is correct and
must be left in the working tree.

## Scope

**In scope**:
- `Squatter/Services/DockerProbe.swift` (create)
- `Squatter/Model/Listener.swift`
- `Squatter/Services/LsofRunner.swift` (add `environment` to `ProcessRunner` only)
- `Squatter/Services/PortScanner.swift`
- `Squatter/Model/Preferences.swift`
- `Squatter/ViewModels/PortListModel.swift`
- `Squatter/Views/PortRow.swift`
- `Squatter/Views/SettingsView.swift` (one toggle)
- `SquatterTests/DockerProbeTests.swift` (create)
- `SquatterTests/Fixtures/docker-ps-sample.txt` (create)
- `SquatterTests/PortScannerTests.swift`, `SquatterTests/PortListModelTests.swift`,
  `SquatterTests/TestDoubles.swift`, `SquatterTests/SnapshotTests.swift`
- `Squatter.xcodeproj/project.pbxproj` (regenerated, never hand-edited)
- `TRACKER.md`, `CHANGELOG.md`, `AGENTS.md`, `PROJECT_SPEC.md`

**Out of scope** (do NOT touch):
- `Squatter/Services/ProcessKiller.swift` and everything about killing. Container rows keep
  today's kill behaviour in this plan; changing it is plan 008's whole job.
- `Squatter/Services/LsofParser.swift` — the parser stays a pure `String -> [Listener]`
  function that knows nothing about Docker. Annotation happens above it, in `PortScanner`.
- `LsofRunner`'s constants and the `lsof` argument list.
- The `docker` CLI's own config, contexts, or anything under `~/.docker`. Read never write.
- `README.md` — the owner updates the feature list at release time.

## Steps

### Step 1: Give `Listener` an optional container

In `Squatter/Model/Listener.swift`, add above `Listener`:

```swift
/// The Docker container that published a host port, when Squatter could identify one.
struct ContainerRef: Hashable, Sendable {
    /// Full container ID from `docker ps --no-trunc`. Used by plan 008 to stop it.
    let id: String
    /// Container name, e.g. `api-db-1`. What the row shows instead of `com.docker.backend`.
    let name: String
    /// Image reference, e.g. `postgres:16`.
    let image: String
    /// The port *inside* the container, which is often different from the host port.
    let containerPort: UInt16

    /// First 12 characters — how `docker ps` prints an ID and how a user would recognise it.
    var shortID: String { String(id.prefix(12)) }
}
```

Then add `let container: ContainerRef?` to `Listener` and an explicit initializer so the
existing call sites (which pass no `container:`) keep compiling:

```swift
    let container: ContainerRef?

    init(
        port: UInt16,
        pid: pid_t,
        processName: String,
        user: String,
        addresses: Set<String>,
        isOwnedByCurrentUser: Bool,
        container: ContainerRef? = nil
    ) { ... assign all seven ... }

    /// Copy of this listener carrying `container`. Annotation happens in `PortScanner`
    /// after parsing, so `LsofParser` stays a pure function that knows nothing about Docker.
    func withContainer(_ container: ContainerRef?) -> Listener {
        Listener(
            port: port, pid: pid, processName: processName, user: user,
            addresses: addresses, isOwnedByCurrentUser: isOwnedByCurrentUser,
            container: container
        )
    }
```

Also add a display helper used by the row and by accessibility text:

```swift
    /// What the row calls this listener: the container name when there is one, otherwise
    /// the process name. `com.docker.backend` tells the user nothing.
    var displayName: String { container?.name ?? processName }
```

**Verify**: `xcodebuild -project Squatter.xcodeproj -scheme Squatter -configuration Debug build`
→ `** BUILD SUCCEEDED **`. No test file needed changing.

### Step 2: Let `ProcessRunner` carry an environment

In `Squatter/Services/LsofRunner.swift`, add to `ProcessRunner` a stored property beside
`timeout`:

```swift
    /// Passed to the child verbatim. `lsof` needs nothing; the `docker` CLI needs `HOME`
    /// to find `~/.docker/config.json` and its current context. Empty stays the default so
    /// nothing inherits the app's environment by accident.
    var environment: [String: String] = [:]
```

and change `process.environment = [:]` to `process.environment = environment`.

Do not change anything else in this file. `LsofRunner` keeps the default and therefore keeps
running with an empty environment exactly as today.

**Verify**:
`grep -n 'process.environment' Squatter/Services/LsofRunner.swift` → exactly one line,
`process.environment = environment`.
Then the build command → `** BUILD SUCCEEDED **`.

### Step 3: Write the `docker ps` fixture

Create `SquatterTests/Fixtures/docker-ps-sample.txt` with exactly these three lines (one
JSON object per line — `docker ps --format '{{json .}}'` emits NDJSON, **not** a JSON array):

```
{"Command":"\"docker-entrypoint.s…\"","CreatedAt":"2026-08-28 10:12:03 +0300 +03","ID":"3f0a1b2c3d4e5f60718293a4b5c6d7e8f90123456789abcdef0123456789abcd","Image":"postgres:16","Labels":"","LocalVolumes":"1","Mounts":"pgdata","Names":"api-db-1","Networks":"api_default","Ports":"0.0.0.0:5432-\u003e5432/tcp, [::]:5432-\u003e5432/tcp","RunningFor":"18 hours ago","Size":"0B","State":"running","Status":"Up 18 hours"}
{"Command":"\"redis-server\"","CreatedAt":"2026-08-28 10:12:04 +0300 +03","ID":"aa11bb22cc33dd44ee55ff6677889900aabbccddeeff00112233445566778899","Image":"redis:7-alpine","Labels":"","LocalVolumes":"0","Mounts":"","Names":"api-cache-1","Networks":"api_default","Ports":"127.0.0.1:6380-\u003e6379/tcp","RunningFor":"18 hours ago","Size":"0B","State":"running","Status":"Up 18 hours"}
{"Command":"\"/docker-entrypoint.…\"","CreatedAt":"2026-08-28 11:02:00 +0300 +03","ID":"bb22cc33dd44ee55ff6677889900aabbccddeeff001122334455667788990011","Image":"nginx:alpine","Labels":"","LocalVolumes":"0","Mounts":"","Names":"edge,edge-alias","Networks":"api_default","Ports":"0.0.0.0:8080-\u003e80/tcp, 0.0.0.0:9000-9002-\u003e9000-9002/tcp, 443/tcp","RunningFor":"2 hours ago","Size":"0B","State":"running","Status":"Up 2 hours"}
```

Three things in that fixture are deliberate and your parser must handle all of them:

1. **`->` arrives as `\u003e`.** Go's JSON encoder HTML-escapes `>`, so the raw bytes never
   contain `->`. `JSONDecoder` unescapes it for you — parse the *decoded* string, never the
   raw output.
2. `api-cache-1` publishes host port **6380** for container port **6379**. Host and container
   ports differ; the row must key off the host port.
3. `edge` has a **port range** (`9000-9002->9000-9002/tcp`), an **unpublished exposed port**
   (`443/tcp`, no arrow — must be skipped), and **two names** (`edge,edge-alias` — take the
   first).

**Verify**: `wc -l < SquatterTests/Fixtures/docker-ps-sample.txt` → `3`, and
`grep -c '\\u003e' SquatterTests/Fixtures/docker-ps-sample.txt` → `3`.

### Step 4: Create `DockerProbe`

Create `Squatter/Services/DockerProbe.swift`. It has four parts; write them in this order.

**4a. The decoded container.** A `Decodable` struct matching the fixture's fields — only
`ID`, `Image`, `Names`, `Ports`, `State` are needed; ignore the rest (`Decodable` skips
unknown keys automatically):

```swift
private struct DockerPSLine: Decodable {
    let ID: String
    let Image: String
    let Names: String
    let Ports: String
    let State: String
}
```

Silence the naming warning with a comment saying these names are dictated by `docker ps`'s
JSON, not by us.

**4b. The pure parser** — a `static func` on an enum or on `DockerProbe`, taking `String`
and returning `[UInt16: ContainerRef]` keyed by **host** port:

```swift
/// Parses `docker ps --no-trunc --format '{{json .}}'` NDJSON into host-port → container.
/// Pure: no I/O, so it is fixture-tested exactly like `LsofParser`.
static func parse(_ output: String) -> [UInt16: ContainerRef]
```

Rules, all of which the fixture exercises:

- Split on newlines, skip empty lines, decode each line independently. **A line that fails
  to decode is skipped, never thrown** — same forward-compatibility posture as `LsofParser`,
  whose doc comment says *"Malformed or non-LISTEN records are skipped, never thrown."*
- Skip any line whose `State != "running"`.
- Container name = `Names` up to the first `,`.
- Split `Ports` on `", "`. For each entry:
  - Skip entries without `"->"` (exposed but not published).
  - Left of `->` is the host binding (`0.0.0.0:5432`, `127.0.0.1:6380`, `[::]:5432`); right
    is `5432/tcp`.
  - **Skip anything not ending in `/tcp`** — Squatter lists TCP only.
  - Host port = the text after the **last** `:` in the left side. Container port = the text
    before `/` on the right.
  - If either side is a range (`9000-9002`), split on `-`, parse both ends, and emit one
    entry per host port, pairing it with the matching offset on the container side when the
    two ranges are the same length (otherwise pair every host port with the range's first
    container port). Refuse ranges wider than 1024 ports — return nothing for that entry
    rather than allocating a huge dictionary from hostile input.
- When two containers claim the same host port (impossible in practice — the second would
  fail to start), first one wins.

**4c. CLI discovery.** A fixed allowlist, checked in order, first executable wins:

```swift
/// Absolute paths only, in a fixed list — never a `PATH` lookup and never a shell, so this
/// stays inside golden rule #7. Covers Docker Desktop, Homebrew, Rancher Desktop and OrbStack.
static let searchPaths: [String] = [
    "/usr/local/bin/docker",
    "/opt/homebrew/bin/docker",
    NSHomeDirectory() + "/.docker/bin/docker",
    NSHomeDirectory() + "/.rd/bin/docker",
    NSHomeDirectory() + "/.orbstack/bin/docker",
    "/Applications/Docker.app/Contents/Resources/bin/docker",
]

static func findExecutable(
    in paths: [String] = searchPaths,
    isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
) -> String?
```

The injected `isExecutable` closure is what makes this testable on a machine with no Docker.

**4d. The actor.** Stale-while-revalidate, so a scan is **never** delayed by `docker`:

```swift
/// Maps host ports to the Docker containers that published them.
///
/// Never blocks a scan: `snapshot()` returns the last known mapping immediately and kicks
/// off a refresh in the background when the cache is stale, so the first list after launch
/// is unannotated and the next one (2 s later) is annotated. `docker ps` talks to the local
/// daemon over a unix socket — nothing leaves the machine.
actor DockerProbe {
    static let arguments = ["ps", "--no-trunc", "--format", "{{json .}}"]
    /// Shorter than lsof's 10 s: this is optional decoration, not the list itself.
    static let timeout: Duration = .seconds(3)
    static let freshFor: Duration = .seconds(5)
    /// After a failure (daemon not running is the common one) back off hard — otherwise a
    /// 2 s poll spawns a failing `docker ps` every two seconds forever.
    static let backoffAfterFailure: Duration = .seconds(30)

    init(runner: (any CommandRunning)? = nil, clock: ContinuousClock = ContinuousClock())
    func setEnabled(_ enabled: Bool)
    /// Cached mapping. Triggers a background refresh when stale; never awaits the subprocess.
    func snapshot() -> [UInt16: ContainerRef]
    /// Runs `docker ps` now and updates the cache. Tests call this to be deterministic.
    func refreshNow() async
}
```

Implementation notes that are load-bearing:

- The default `runner` is `nil` meaning "build one from `findExecutable()`". If
  `findExecutable()` returns `nil`, the probe is permanently inert: `snapshot()` returns
  `[:]`, `refreshNow()` does nothing, and **no process is ever spawned**. A machine without
  Docker must pay nothing beyond the one-time path check.
- Build the real runner as
  `ProcessRunner(executablePath: path, arguments: Self.arguments, timeout: Self.timeout, environment: ["HOME": NSHomeDirectory()])`
  wrapped in a tiny `struct DockerRunner: CommandRunning` (mirroring `LsofRunner`), or
  make `ProcessRunner` itself conform — either is fine, but the argument list must be the
  `static let` above, not built inline.
- `refreshNow()` ignores errors entirely: any thrown error, non-zero exit, or non-UTF-8
  output sets `failureUntil = now + backoffAfterFailure` and leaves the previous cache in
  place. **Docker being absent or stopped is normal, not an error the user should see.**
- Only one refresh in flight at a time (same reasoning as `PortScanner.inFlight`).
- `setEnabled(false)` clears the cache and stops all refreshes.

**Verify**: `xcodegen generate` → project regenerated, then the build command →
`** BUILD SUCCEEDED **`, then
`grep -n 'Process(' Squatter/Services/DockerProbe.swift` → **no matches** (you go through
`ProcessRunner`, you do not construct `Process` yourself).

### Step 5: Test `DockerProbe` against the fixture

Create `SquatterTests/DockerProbeTests.swift`, modelled structurally on
`SquatterTests/LsofParserTests.swift` (fixture + edge cases) and using the `FakeRunner`
already in `SquatterTests/TestDoubles.swift`:

```swift
actor FakeRunner: CommandRunning {   // existing — do not redefine
    init(_ result: Result<CommandResult, ScanError>, delay: Duration = .zero)
    func set(_ result: Result<CommandResult, ScanError>)
    private(set) var launches: Int
}
```

`lsofResult(_ stdout: String, code: Int32 = 0, stderr: String = "")` in the same file builds
a `CommandResult`; reuse it rather than writing another.

Write at least these seven tests:

1. `fixtureMapsHostPortsToContainers` — load `docker-ps-sample.txt` from the test bundle.
   Copy the idiom `LsofParserTests.swift:123-125,138` uses verbatim — a private anchor class
   is how the test bundle is located, and guessing at this wastes a cycle:

   ```swift
   let url = try #require(Bundle(for: Anchor.self).url(forResource: "docker-ps-sample", withExtension: "txt"))
   let text = try String(contentsOf: url, encoding: .utf8)
   ...
   private final class Anchor {}   // at file scope, bottom of the file
   ```

   Parse it and expect
   `5432 → api-db-1 (postgres:16, containerPort 5432)`,
   `6380 → api-cache-1 (redis:7-alpine, containerPort 6379)`,
   `8080 → edge (nginx:alpine, containerPort 80)`.
2. `portRangesExpand` — the same fixture yields `9000`, `9001`, `9002` all mapped to `edge`,
   with container ports `9000`, `9001`, `9002` respectively.
3. `unpublishedAndUdpPortsAreSkipped` — `443` is absent from the map; a hand-written line
   with `0.0.0.0:5300->53/udp` yields nothing.
4. `nonRunningContainersAreSkipped` — a line with `"State":"exited"` yields nothing.
5. `garbageLinesAreSkippedNotThrown` — `"not json\n" + <one good line>` still yields the good
   container.
6. `absentDockerNeverSpawnsAProcess` — `DockerProbe.findExecutable(in: ["/nope"], isExecutable: { _ in false })`
   is `nil`; a probe built that way returns `[:]` from `snapshot()` and its injected
   `FakeRunner` reports `launches == 0` after `refreshNow()`.
7. `failureBacksOffAndKeepsTheLastGoodMapping` — probe with a `FakeRunner` scripted to
   succeed; `await refreshNow()`; re-script it to `.failure(.launchFailed("daemon"))`;
   `await refreshNow()`; the snapshot still contains `api-db-1` and no error surfaces.

**Verify**: the test command → `** TEST SUCCEEDED **` and the run reports **at least 91
tests** (84 baseline + 7).

### Step 6: Merge the annotation in `PortScanner`

Give `PortScanner` an optional probe and annotate after parsing:

```swift
    private let docker: DockerProbe?

    init(
        runner: any CommandRunning = LsofRunner(),
        currentUID: uid_t = getuid(),
        userName: @escaping UserNameResolver = LsofParser.defaultUserName,
        docker: DockerProbe? = DockerProbe()
    )

    /// Forwarded from the Docker Integration setting.
    func setDockerEnabled(_ enabled: Bool) async { await docker?.setEnabled(enabled) }
```

Inside the `Task` in `scan()`, after `Self.listeners(from:...)` produces the array:

```swift
            let listeners = try Self.listeners(from: result, currentUID: currentUID, userName: userName)
            guard let docker else { return listeners }
            let containers = await docker.snapshot()
            guard !containers.isEmpty else { return listeners }
            return listeners.map { $0.withContainer(containers[$0.port]) }
```

Note `docker` must be captured in the `Task`'s capture list alongside the others.

Two constraints:

- `snapshot()` must not await a subprocess (step 4d) — if a scan ever measurably slows down
  when Docker is running, you have implemented the cache wrong. STOP and report.
- Do **not** filter or reorder listeners here. Annotation only.

**Verify**: add to `SquatterTests/PortScannerTests.swift` a test
`dockerAnnotationAttachesContainersByHostPort` that builds a `PortScanner` with a
`FakeRunner` serving `sampleLsof` plus a `5432` row, and a `DockerProbe` fed the fixture,
calls `refreshNow()` on the probe first, then `scan()`, and expects the 5432 listener's
`container?.name == "api-db-1"` while the 3000 listener's `container` is `nil`. Test command
→ `** TEST SUCCEEDED **`.

### Step 7: Add the preference and wire it through the model

In `Squatter/Model/Preferences.swift`:

```swift
    static let dockerIntegration = "squatter.dockerIntegration"   // in DefaultsKeys
...
    /// On by default: with no Docker CLI installed nothing is ever spawned, so the cost of
    /// leaving it on is zero. Off is the escape hatch for anyone who wants no second process.
    var dockerIntegration: Bool {
        get {
            guard defaults.object(forKey: DefaultsKeys.dockerIntegration) != nil else { return true }
            return defaults.bool(forKey: DefaultsKeys.dockerIntegration)
        }
        nonmutating set { defaults.set(newValue, forKey: DefaultsKeys.dockerIntegration) }
    }
```

In `Squatter/ViewModels/PortListModel.swift`, beside the existing `showCountInMenuBar`
observable property (which follows exactly this shape):

```swift
    /// Annotate Docker-published ports with their container. Off means Squatter never runs
    /// the `docker` CLI.
    var dockerIntegration: Bool {
        didSet {
            preferences.dockerIntegration = dockerIntegration
            let enabled = dockerIntegration
            Task { [scanner] in await scanner.setDockerEnabled(enabled) }
        }
    }
```

Initialise it from `preferences.dockerIntegration` in `init` (next to
`self.showCountInMenuBar = preferences.showCountInMenuBar`) and push the initial value to the
scanner there too.

In `Squatter/Views/SettingsView.swift`, in the same `Section` as
`Toggle("Show count in menu bar", …)`:

```swift
                Toggle("Docker integration", isOn: $model.dockerIntegration)
```

Sentence case, per `rules/ux-writing.md` — **not** "Docker Integration". Add to that
section's existing `footer:` text, or as a second footer line:
`"Names the container behind a published port. Squatter only runs the docker command when Docker is installed."`

**Verify**: `grep -rn 'squatter\.' Squatter/Model/Preferences.swift` → six keys, all prefixed
`squatter.`. Add a `PortListModelTests` case `dockerIntegrationDefaultsOnAndPersists` (model
after the existing `defaultsAndRoundTrip` test at `PortListModelTests.swift:522`). Test
command → `** TEST SUCCEEDED **`.

### Step 8: Show the container in the row

In `Squatter/Views/PortRow.swift`, in `details`:

- Replace `Text(listener.processName)` with a title line that, when
  `listener.container != nil`, renders an SF Symbol `shippingbox.fill` (`.caption`,
  `.secondary`) followed by `Text(listener.displayName)`. When `container == nil` the line is
  exactly what it is today — one `Text(listener.processName)`.
- In the caption `HStack`, when `listener.container != nil`, render
  `Text(verbatim: container.image)` in place of `Text(verbatim: "PID \(listener.pid)")`.
  The PID of `com.docker.backend` is the same for every container row and tells the user
  nothing; the image tells them what it is. Address chips stay.
- Add `.help()` on the symbol:
  `Text("Published by Docker container \(container.name) → port \(String(container.containerPort))")`
  — sentence case.
- Extend `accessibilityText` so a container row reads
  `"api-db-1, Docker container from postgres:16, on port 5432"`. Keep the existing
  `, owned by <user>` and `, ignored` suffixes working.

Do **not** change `hoverActions`, `menuItems`, `trailing`, or `ledColor` in this plan.
Kill behaviour is plan 008.

**Verify**: build, then extend `SquatterTests/SnapshotTests.swift` — in
`rendersListEmptyAndErrorStates`, build one extra model whose `PortScanner` is given a
`DockerProbe` fed the fixture (refreshed first) and an lsof string containing
`p600\nccom.docker.backend\nu501\nf1\nPTCP\nn*:5432\nTST=LISTEN\n`, and snapshot it as
`"list-docker"`. Add its URL to the existing size-check loop at the end of the test. Test
command → `** TEST SUCCEEDED **`; then open the PNG printed after `SNAPSHOTS:` and confirm
the row says `api-db-1` and `postgres:16`, not `com.docker.backend`.

### Step 9: Update the docs that now describe something untrue

- `AGENTS.md`, golden rule #7 — currently: *"Never spawn a shell. `lsof` is invoked by
  absolute path with fixed arguments via `Process`; processes are killed with `kill(2)`
  only after re-validating the PID still maps to the scanned process name."* Extend the
  first sentence to cover the second subprocess, e.g.: *"Never spawn a shell. `lsof` and
  `docker` are invoked by absolute path — `docker` from a fixed allowlist in
  `DockerProbe.searchPaths`, never a `PATH` lookup — with fixed arguments via `Process`;
  …"*. Keep the rest of the rule verbatim.
- `PROJECT_SPEC.md:73` — the P2 Docker bullet. Tick the annotation half and note that
  "Stop container" is still pending (plan 008).
- `TRACKER.md` — add a dated entry under `## Dev changelog` (newest first, at the top of the
  list) describing what landed and why annotation shipped before the stop action. Match the
  voice of the existing entries: what changed, what it fixes, what was verified.
- `CHANGELOG.md` — under `[Unreleased]` → `### Added`, one user-facing line, e.g.
  *"Ports published by a Docker container now show the container's name and image instead
  of `com.docker.backend`."* Write for users, not developers.

**Verify**: `git status --short` lists only files from the In-scope list.

## Test plan

| File | Tests | Pattern to follow |
|------|-------|-------------------|
| `SquatterTests/DockerProbeTests.swift` (new) | the seven in step 5 | `SquatterTests/LsofParserTests.swift` (fixture-driven pure parsing) |
| `SquatterTests/PortScannerTests.swift` | `dockerAnnotationAttachesContainersByHostPort` | the existing tests in that file |
| `SquatterTests/PortListModelTests.swift` | `dockerIntegrationDefaultsOnAndPersists` | `defaultsAndRoundTrip`, line 522 |
| `SquatterTests/SnapshotTests.swift` | `"list-docker"` snapshot | the existing snapshots in `rendersListEmptyAndErrorStates` |

Expect **at least 93 tests** total (84 + 7 + 1 + 1) once every step has landed.

## Done criteria

ALL must hold:

- [ ] `xcodegen generate` run after every new file; `Squatter.xcodeproj/project.pbxproj`
      appears in `git status`
- [ ] `xcodebuild -project Squatter.xcodeproj -scheme Squatter -configuration Debug build` →
      `** BUILD SUCCEEDED **` (warnings are errors here — `SWIFT_TREAT_WARNINGS_AS_ERRORS: YES`)
- [ ] `xcodebuild -project Squatter.xcodeproj -scheme Squatter -destination 'platform=macOS' test` →
      `** TEST SUCCEEDED **`, ≥ 93 tests, zero failures
- [ ] `grep -rn 'Process(' Squatter/Services/DockerProbe.swift` → no matches
- [ ] `grep -rn '/bin/sh\|/bin/bash\|launchPath\|PATH' Squatter/Services/DockerProbe.swift` → no matches
- [ ] `grep -c 'searchPaths' Squatter/Services/DockerProbe.swift` → ≥ 1, and every entry in
      that array is an absolute path or `NSHomeDirectory() + …`
- [ ] `grep -n 'docker' Squatter/Services/LsofParser.swift` → no matches (the parser stayed pure)
- [ ] `grep -n 'requestKill\|forceKill' Squatter/Views/PortRow.swift` → same lines as before
      this plan (kill behaviour unchanged)
- [ ] The `list-docker` snapshot PNG shows the container name, confirmed by eye
- [ ] `TRACKER.md` has a new dated entry; `CHANGELOG.md` has an `[Unreleased]` line
- [ ] Nothing committed, nothing pushed, no Linear issue touched
- [ ] `plans/README.md` status row for 007 updated

## STOP conditions

Stop and report — do not improvise — if:

- The drift check shows any in-scope file changed since `947e97c` and the excerpts above no
  longer match the code.
- Adding `container` to `Listener` breaks call sites you cannot fix without editing files
  outside the scope list. (It should not: step 1's explicit `init` with a defaulted
  parameter exists precisely to prevent this.)
- A scan measurably slows down with Docker running — that means `snapshot()` is awaiting the
  subprocess and the design is wrong.
- You conclude the container mapping needs to key off the process name (`com.docker.backend`)
  rather than the host port. It must not: matching by host port is what makes this work under
  OrbStack, Colima and Rancher Desktop, whose proxy processes have different names. If host-port
  matching seems wrong, report why rather than switching approaches.
- You find yourself wanting to shell out, use `PATH`, or read `DOCKER_HOST` from the user's
  shell configuration. Report instead.
- **You have Docker installed and the real output does not match the fixture's shape.**
  Capture the real output of `docker ps --no-trunc --format '{{json .}}'` (redacting anything
  private), update the fixture, and note the difference in your report.

## Maintenance notes

- **Nobody on this project has verified this against a real Docker daemon.** Docker is not
  installed on the owner's machine (checked 2026-08-29: no `docker` on `PATH`, no
  `/var/run/docker.sock`). Everything here is fixture-driven, and the fixture was written
  from the documented `docker ps` format, not captured from a live daemon. **The owner must
  run the app once with Docker Desktop running before this ships** — that manual check
  belongs in `TRACKER.md` as an open box, next to the existing "Manual check: Launch at Login
  toggle against the signed build".
- The port-range expansion and the `>` escaping are the two parsing details most likely
  to be wrong against a real daemon. A reviewer should read those two branches closely.
- If `docker ps` ever gains a stable machine-readable flag for host bindings, the string
  parsing in `parse` becomes unnecessary — it exists only because `Ports` is a display string.
- Deferred out of this plan on purpose: podman (`podman ps` speaks the same format and could
  be added to `searchPaths`, but nobody asked), non-TCP publishes, and containers on a remote
  Docker context (`snapshot()` would happily annotate a port that is not on this machine —
  in practice a remote context publishes no local ports, so nothing matches).
