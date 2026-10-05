# Plan 001: Make every kill path confirm, and enforce ownership in the model

> **Notion tracking — 2026-09-06:** Current task tracking is in Notion: [Squatter](https://app.notion.com/p/3d3cacb0997081acbbbbfc2bd0f0ddf8), [Tasks](https://app.notion.com/p/3d2cacb09970808d99b7f3c0c0a36f35). Any Linear URLs, IDs, statuses or refusals below are historical references. Resolve migrated IDs via `Linear ID` and verify `Project`; use the Notion task page for all new updates. This supersedes instructions below to create, query, update or close Linear issues. Follow the current repository tracking rule, including its owner-review requirements.

> **Executor instructions**: Follow this plan step by step. Run every verification
> command and confirm the expected result before moving to the next step. If anything
> in the "STOP conditions" section occurs, stop and report — do not improvise. When
> done, update the status row for this plan in `plans/README.md`.
>
> **Drift check (run first)**:
> `git diff --stat 9c7eef2..HEAD -- Squatter/ViewModels/PortListModel.swift Squatter/Views/PortRow.swift SquatterTests/PortListModelTests.swift SquatterTests/SnapshotTests.swift PROJECT_SPEC.md`
> If any of those files changed since this plan was written, compare the "Current state"
> excerpts below against the live code before proceeding; on a mismatch, treat it as a
> STOP condition.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: bug
- **Planned at**: commit `9c7eef2`, 2026-08-28

## Why this matters

Squatter is a menu bar app that kills processes. Its stated safety contract
(`PROJECT_SPEC.md`, "Interaction details") is that **every kill path confirms first**.
Three of the four paths do: the ✕ button, the "Kill Process" menu item, the ⌫ key and
the accessibility action all arm an inline "Kill this process?" prompt. The fourth —
the **"Force Kill" item in the row's right-click / ⋯ menu** — calls
`model.forceKill(listener)` directly and sends **SIGKILL with no confirmation at all**.
It sits two items below "Kill Process" in the same menu, so a single misclick
unrecoverably SIGKILLs a developer's running server with no chance to back out and no
undo. SIGKILL cannot be caught, so the process gets no opportunity to flush state or
shut down cleanly.

Separately, the model's ownership check is only enforced on the *arming* methods
(`requestKill`, `killSelected`). `kill(_:)` and `forceKill(_:)` will happily signal any
listener handed to them; today the only thing preventing a SIGKILL aimed at another
user's process is a `.disabled(!canKill)` modifier in the view. That is a view-layer
guard on a model-layer invariant.

After this plan: every path that can signal a process passes through a confirmation, the
model refuses to signal processes the user does not own regardless of which view calls
it, and an armed confirmation does not survive the popover being dismissed.

## Current state

Files involved, and their roles:

- `Squatter/ViewModels/PortListModel.swift` — `@MainActor @Observable` model; single source
  of truth for the popover. Owns `KillState`, the `killStates` dictionary, and every
  kill/confirm method.
- `Squatter/Views/PortRow.swift` — one listener row. Renders the confirmation UI and
  builds the shared menu used by both the ⋯ button and the right-click menu.
- `SquatterTests/PortListModelTests.swift` — model tests, including a `MARK: kill confirmation`
  section that already covers the SIGTERM confirmation flow.
- `SquatterTests/SnapshotTests.swift` — renders the popover offscreen to PNGs; asserts only
  that each PNG is non-blank.

### The bug — `Squatter/Views/PortRow.swift:208-235`

```swift
    @ViewBuilder
    private var menuItems: some View {
        Button("Open in Browser", systemImage: "arrow.up.right.square") { model.open(listener) }
        Divider()
        Button("Copy URL", systemImage: "doc.on.doc") { model.copyURL(listener) }
        Button("Copy Port", systemImage: "number") { model.copyPort(listener) }
        Button("Copy PID", systemImage: "tag") { model.copyPID(listener) }
        Divider()
        Button("Kill Process", systemImage: "xmark.circle", role: .destructive) {
            model.requestKill(listener)          // <-- arms a confirmation
        }
        .disabled(!canKill)
        Button("Force Kill", systemImage: "bolt.fill", role: .destructive) {
            Task { await model.forceKill(listener) }   // <-- BUG: sends SIGKILL immediately
        }
        .disabled(!canKill)
```

### The `KillState` enum — `Squatter/ViewModels/PortListModel.swift:4-15`

```swift
/// Per-row progress of a kill request.
enum KillState: Equatable, Sendable {
    /// Kill was requested; waiting for the user to confirm before any signal is sent.
    case confirming
    /// SIGTERM sent; waiting up to the grace period for the process to exit.
    case terminating
    /// Still alive after the grace period — the UI offers Force Kill.
    case stillRunning
    /// SIGKILL sent; waiting for exit.
    case forcing
    case failed(String)
}
```

### The confirmation methods — `Squatter/ViewModels/PortListModel.swift:198-245`

```swift
    /// Arms the confirmation. Nothing is signalled until `kill(_:)`.
    /// Only one row can be armed at a time — arming a new one cancels the previous.
    func requestKill(_ listener: Listener) {
        guard listener.isOwnedByCurrentUser, killStates[listener.id] == nil else { return }
        cancelAllKillConfirmations()
        killStates[listener.id] = .confirming
    }

    func cancelKill(_ listener: Listener) {
        guard killStates[listener.id] == .confirming else { return }
        killStates[listener.id] = nil
    }

    /// True while any row is waiting for confirmation — lets Escape cancel from the list.
    var isAwaitingKillConfirmation: Bool { killStates.values.contains(.confirming) }

    func cancelAllKillConfirmations() {
        killStates = killStates.filter { $0.value != .confirming }
    }

    func kill(_ listener: Listener) async {
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

    func forceKill(_ listener: Listener) async {
        killStates[listener.id] = .forcing
        do {
            try killer.terminate(listener, force: true)
        } catch {
            killStates[listener.id] = .failed(error.localizedDescription)
            return
        }
        _ = await killer.waitForExit(of: listener, timeout: forceKillWait)
        killStates[listener.id] = nil
        await refresh()
    }
```

### Polling stop — `Squatter/ViewModels/PortListModel.swift:159-163`

```swift
    /// Popover closed: back to background cadence if the badge is on, otherwise stop entirely.
    func stopPolling() {
        isPopoverVisible = false
        restartPollingLoop()
    }
```

`PortListView.swift:20` calls this from `.onDisappear`. Because the model is owned by
`SquatterApp` (`@State private var model = PortListModel()`) it outlives the popover, so
an armed `.confirming` state survives a close/reopen indefinitely.

### The confirmation UI — `Squatter/Views/PortRow.swift:53-79` (the second line of the row)

```swift
    private var details: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(listener.processName)
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .foregroundStyle(isIgnored ? .secondary : .primary)
            if killState == .confirming {
                // The name above already says which process; this line asks, so the buttons
                // never have to compete with a long name for width.
                Text("Kill this process?")
                    .font(.caption2)
                    .foregroundStyle(.red)
            } else {
```

### The confirmation UI — `Squatter/Views/PortRow.swift:97-137` (the trailing controls)

```swift
    @ViewBuilder
    private var trailing: some View {
        switch killState {
        case nil:
            if isHovering || isSelected {
                hoverActions
            }
        case .confirming:
            // The row already names the process, so the prompt stays short — long names
            // would otherwise squeeze the buttons into ellipses.
            HStack(spacing: 8) {
                Button("Cancel") { model.cancelKill(listener) }
                    .controlSize(.small)
                    .keyboardShortcut(.cancelAction)
                Button("Kill", role: .destructive) {
                    Task { await model.kill(listener) }
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.small)
                .accessibilityLabel(Text("Confirm killing \(listener.processName) on port \(String(listener.port))"))
            }
            .fixedSize()
        case .terminating:
            progress(Text("Killing…"))
```

### The LED colour — `Squatter/Views/PortRow.swift:83-93`

```swift
    private var ledColor: Color {
        switch killState {
        case .confirming: .red
        case .terminating, .forcing: .orange
        case .stillRunning, .failed: .red
        case nil:
            if isIgnored { .primary.opacity(0.15) }
            else if canKill { .green }
            else { .secondary.opacity(0.5) }
        }
    }
```

### Conventions you must match

Inlined from `AGENTS.md` and `rules/ux-writing.md` — you have not read those files:

- **UI copy**: Title Case for buttons and menu labels; sentence case everywhere else.
  Buttons are verb + object ("Kill Process", "Force Kill" — never "OK"/"Yes"). The
  destructive verb is **Kill**, not "Terminate" or "End".
- **Views hold no logic.** All decisions live in `PortListModel`; `PortRow` only renders
  state and calls model methods. Do not put an `isOwnedByCurrentUser` check inside a
  button action — it belongs in the model.
- **Every user-facing string** goes through `String(localized:)` or a SwiftUI `Text`
  literal. Follow the surrounding code exactly.
- **Accessibility**: every button that appears on a row carries an `.accessibilityLabel`
  naming the process and port — see the existing `.confirming` case above and copy its shape.
- **Tests use Swift Testing** (`@Test`, `#expect`, `#require`), never XCTest.
- **Comment density**: this repo comments *why*, not *what*, and only where a reader would
  otherwise be puzzled. Match it; do not add narration.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Build | `xcodebuild -project Squatter.xcodeproj -scheme Squatter -configuration Debug build` | exit 0, no warnings (warnings are errors: `SWIFT_TREAT_WARNINGS_AS_ERRORS: YES`) |
| Test | `xcodebuild -project Squatter.xcodeproj -scheme Squatter -destination 'platform=macOS' test` | exit 0; final line reports **74 tests** passing (69 today + 5 new) |

Run these from the repo root. There is no lint step and no package manager — zero
third-party dependencies.

## Scope

**In scope** (the only files you may modify):
- `Squatter/ViewModels/PortListModel.swift`
- `Squatter/Views/PortRow.swift`
- `SquatterTests/PortListModelTests.swift`
- `SquatterTests/SnapshotTests.swift`
- `PROJECT_SPEC.md` (one line — step 7)
- `TRACKER.md`, `CHANGELOG.md` (step 8)

**Out of scope** (do NOT touch, even though they look related):
- `Squatter/Services/ProcessKiller.swift` — the `kill(2)` layer and its PID re-validation
  are correct and separately tested. This plan changes *who may ask*, not *how it signals*.
- `Squatter/Views/PortListView.swift` — the Escape handler already routes through
  `model.cancelAllKillConfirmations()`, which this plan widens. No view change is needed there.
- `Squatter/Views/SettingsView.swift`, `Squatter/ViewModels/SettingsModel.swift`.
- The existing `.confirming` SIGTERM flow — do not rename, re-shape, or "unify" it with
  the new state. Existing tests assert `killStates[id] == .confirming` by equality and
  must keep passing untouched.
- `Squatter.xcodeproj` — generated from `project.yml`; no new files are added by this plan.

## Git workflow

**Do not commit anything.** This repo gates commits behind owner approval
(`rules/core-workflow.md`: "Before committing user-visible work: CHANGELOG gate → release
gate → build/verify → commit"). Leave every change in the working tree and report what you
changed. Do not `git add`, do not commit, do not push, do not open a PR.

Do **not** update Linear. The repo's golden rule #8 requires a Linear issue update for
every TRACKER change, but that is the owner's step — just note in your report that
`TRACKER.md` changed and a matching Linear issue is needed.

## Steps

### Step 1: Add a `.confirmingForce` state

In `Squatter/ViewModels/PortListModel.swift`, add one case to `KillState`, immediately
after `case confirming`:

```swift
    /// Kill was requested; waiting for the user to confirm before any signal is sent.
    case confirming
    /// Force Kill was requested from the menu; waiting for confirmation before SIGKILL.
    case confirmingForce
```

Do not change any other case, and do not give the new case an associated value.

**Verify**: `xcodebuild -project Squatter.xcodeproj -scheme Squatter -configuration Debug build`
→ exit 0. (`PortRow.ledColor` and `PortRow.trailing` switch over `KillState`; Swift's
exhaustiveness checking may already flag them here. If the build fails with "switch must be
exhaustive" in `PortRow.swift`, that is expected — continue to step 3 and re-run this
verification at the end of step 3.)

### Step 2: Widen the confirmation methods and add `requestForceKill`

Still in `Squatter/ViewModels/PortListModel.swift`, in the `// MARK: Kill` section:

1. Add `requestForceKill(_:)` directly after `requestKill(_:)`, mirroring its shape:

```swift
    /// Arms the Force Kill confirmation. Nothing is signalled until `forceKill(_:)`.
    func requestForceKill(_ listener: Listener) {
        guard listener.isOwnedByCurrentUser, killStates[listener.id] == nil else { return }
        cancelAllKillConfirmations()
        killStates[listener.id] = .confirmingForce
    }
```

2. Widen `cancelKill(_:)` so it clears either armed state:

```swift
    func cancelKill(_ listener: Listener) {
        guard Self.isConfirming(killStates[listener.id]) else { return }
        killStates[listener.id] = nil
    }
```

3. Widen `isAwaitingKillConfirmation` and `cancelAllKillConfirmations()`, and add the
   shared predicate they all use:

```swift
    /// True while any row is waiting for confirmation — lets Escape cancel from the list.
    var isAwaitingKillConfirmation: Bool { killStates.values.contains(where: Self.isConfirming) }

    func cancelAllKillConfirmations() {
        killStates = killStates.filter { !Self.isConfirming($0.value) }
    }

    /// The two armed-but-unsignalled states. Anything else is a kill already in flight
    /// and must survive cancellation.
    private static func isConfirming(_ state: KillState?) -> Bool {
        state == .confirming || state == .confirmingForce
    }
```

**Verify**: `xcodebuild -project Squatter.xcodeproj -scheme Squatter -destination 'platform=macOS' test`
→ exit 0, 69 tests pass. No test changes yet; this step must not break anything.

### Step 3: Refuse to signal processes the user does not own

Still in `Squatter/ViewModels/PortListModel.swift`, add an ownership guard as the **first
line** of both `kill(_:)` and `forceKill(_:)`:

```swift
    func kill(_ listener: Listener) async {
        guard listener.isOwnedByCurrentUser else { return }
        killStates[listener.id] = .terminating
        ...
    }

    func forceKill(_ listener: Listener) async {
        guard listener.isOwnedByCurrentUser else { return }
        killStates[listener.id] = .forcing
        ...
    }
```

**Critical**: add *only* the ownership guard. Do **not** add a guard requiring the row to
already be in a `.confirming` / `.confirmingForce` / `.stillRunning` state — several
existing tests (`PortListModelTests.killThatExitsRemovesRowAndState`,
`stubbornProcessOffersForceKillThenDies`, `killErrorIsSurfacedAndDismissable`) and
`SnapshotTests.swift:55` call `model.kill(_:)` and `model.forceKill(_:)` directly without
arming first, and such a guard would break them.

**Verify**: `xcodebuild -project Squatter.xcodeproj -scheme Squatter -destination 'platform=macOS' test`
→ exit 0, 69 tests pass.

### Step 4: Clear armed confirmations when the popover closes

Still in `Squatter/ViewModels/PortListModel.swift`, in `stopPolling()`:

```swift
    /// Popover closed: back to background cadence if the badge is on, otherwise stop entirely.
    /// An armed confirmation is dropped — the model outlives the popover, and a Kill button
    /// left primed from a previous session is not a prompt the user is still answering.
    func stopPolling() {
        isPopoverVisible = false
        cancelAllKillConfirmations()
        restartPollingLoop()
    }
```

Kills already in flight (`.terminating`, `.stillRunning`, `.forcing`, `.failed`) are
untouched, because `cancelAllKillConfirmations()` only clears the two armed states.

**Verify**: `xcodebuild -project Squatter.xcodeproj -scheme Squatter -destination 'platform=macOS' test`
→ exit 0, 69 tests pass.

### Step 5: Route the menu's Force Kill through the confirmation

In `Squatter/Views/PortRow.swift`, in `menuItems`, change only the Force Kill action:

```swift
        Button("Force Kill", systemImage: "bolt.fill", role: .destructive) {
            model.requestForceKill(listener)
        }
        .disabled(!canKill)
```

Leave the label, symbol, role and `.disabled` modifier exactly as they are.

**Verify**: `grep -in "forceKill" Squatter/Views/PortRow.swift` → exactly two matches: the
`requestForceKill(listener)` call in `menuItems`, and the `await model.forceKill(listener)`
call inside the `.stillRunning` case of `trailing` (that one is the legitimate second step
of the SIGTERM → still running → Force Kill flow and must stay). **The `-i` is required**:
`grep` is case-sensitive and plain `forceKill` does not match `requestForceKill`.

### Step 6: Render the new state

Still in `Squatter/Views/PortRow.swift`:

1. `ledColor` — treat the new state like the other armed state:

```swift
        case .confirming, .confirmingForce: .red
```

2. `details` — replace the `if killState == .confirming { ... }` branch with a prompt that
   covers both states. Add a computed property next to `killState` at the top of the struct:

```swift
    /// The question this row is asking, or `nil` when it is not awaiting confirmation.
    private var confirmationPrompt: Text? {
        switch killState {
        case .confirming: Text("Kill this process?")
        case .confirmingForce: Text("Force kill this process?")
        default: nil
        }
    }
```

   and use it in `details`, keeping the existing comment and styling:

```swift
            if let confirmationPrompt {
                // The name above already says which process; this line asks, so the buttons
                // never have to compete with a long name for width.
                confirmationPrompt
                    .font(.caption2)
                    .foregroundStyle(.red)
            } else {
```

3. `trailing` — add a `.confirmingForce` case directly after the `.confirming` case,
   mirroring it exactly except for the button label and the model call:

```swift
        case .confirmingForce:
            HStack(spacing: 8) {
                Button("Cancel") { model.cancelKill(listener) }
                    .controlSize(.small)
                    .keyboardShortcut(.cancelAction)
                Button("Force Kill", role: .destructive) {
                    Task { await model.forceKill(listener) }
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.small)
                .accessibilityLabel(Text("Confirm force killing \(listener.processName) on port \(String(listener.port))"))
            }
            .fixedSize()
```

The `.fixedSize()` and `.controlSize(.small)` are load-bearing: an earlier bug
(commit `4c072d2`) had these buttons collapsing into ellipses on rows with long process
names. Do not drop them.

**Verify**: `xcodebuild -project Squatter.xcodeproj -scheme Squatter -configuration Debug build`
→ exit 0 with no warnings.

### Step 7: Update the spec's interaction contract

In `PROJECT_SPEC.md`, find the line under "Interaction details" that currently reads:

```
- Kill button is a small ✕ that appears on hover. **Every kill path confirms first** (owner decision 2026-08-28, overriding the original fast-path design): ✕, the Kill Process menu item, and ⌫ all arm an inline "Kill <process>?" with Kill / Cancel; Escape cancels. SIGKILL keeps its own two-step confirmation.
```

Replace it with:

```
- Kill button is a small ✕ that appears on hover. **Every kill path confirms first** (owner decision 2026-08-28, overriding the original fast-path design): ✕, the Kill Process menu item, and ⌫ all arm an inline "Kill this process?" with Kill / Cancel; Escape cancels. The menu's Force Kill arms its own "Force kill this process?" prompt, and the Force Kill offered after a SIGTERM grace period is already the second step of a two-step flow. An armed prompt is dropped when the popover closes.
```

**Verify**: `grep -c "Force kill this process?" PROJECT_SPEC.md` → `1`

### Step 8: Update the tracking docs

`TRACKER.md` — add a new entry at the **top** of the "Dev changelog" list (newest first),
matching the style of the entries around it (one paragraph, past tense, test count, no
trailing issue reference since you cannot create one):

```
- **2026-08-28** — Closed the last unconfirmed kill path: the row menu's Force Kill armed nothing and sent SIGKILL on click, so it now arms its own `KillState.confirmingForce` ("Force kill this process?" with Cancel / Force Kill), Escape and a new arming both clear it, and `PortListModel.kill`/`forceKill` refuse rows the user doesn't own instead of relying on the view's `.disabled`. Armed prompts are also dropped when the popover closes. 5 tests, 74 total.
```

`CHANGELOG.md` — add one bullet under `## [Unreleased]` → `### Fixed`, in plain
user-facing language with no file names or type names:

```
- Force Kill in the right-click menu now asks before it acts. Previously it killed the process the instant you clicked it, with no way to back out.
```

**Verify**: `head -20 CHANGELOG.md` → the bullet appears under `### Fixed`, and
`grep -n "confirmingForce" TRACKER.md` → one match in the newest entry.

## Test plan

Add all new tests to `SquatterTests/PortListModelTests.swift`, inside the existing
`// MARK: kill confirmation` section, immediately after
`confirmationIsRefusedForOtherUsersRows()`. Model their structure on
`killPathsArmAConfirmationInsteadOfSignalling()` and `armingASecondRowCancelsTheFirst()`,
which are already in that file. The helpers `makeModel`, `FakeRunner`, `KillRecorder`,
`lsofResult`, `sampleLsof` and `sampleListener` are defined in the file itself and in
`SquatterTests/TestDoubles.swift` — use them, do not write new fakes.

Reference values you will need: `sampleListener` is `node`, port 3000, PID 42, owned by
the current user. A root-owned row is produced by the fixture string
`"p1\nclaunchd\nu0\nf1\nPTCP\nn*:22\nTST=LISTEN\n"` with `KillRecorder(names: [1: "launchd"])`,
and its id is `"1:22"`. A second owned row is
`"p7\ncpostgres\nu501\nf1\nPTCP\nn127.0.0.1:5432\nTST=LISTEN\n"` with `7: "postgres"` in the
recorder.

Write exactly these five tests:

1. `forceKillFromTheMenuArmsAConfirmationInsteadOfSignalling()` — refresh, call
   `model.requestForceKill(sampleListener)`, expect `killState == .confirmingForce`,
   `model.isAwaitingKillConfirmation == true`, and `kills.signals.isEmpty`. Then
   `model.cancelKill(sampleListener)` and expect the state is `nil` and still no signals.
   **This is the regression test for the bug.**

2. `confirmedForceKillSendsSigkillAndNothingElse()` — recorder with
   `kills.onSignal { pid, _ in kills.setName(nil, for: pid) }`, refresh,
   `model.requestForceKill(sampleListener)`, then `await model.forceKill(sampleListener)`.
   Expect `kills.signals.map(\.1) == [SIGKILL]` — in particular no SIGTERM — and
   `model.killState(for: sampleListener) == nil`.

3. `forceKillConfirmationIsRefusedForOtherUsersRows()` — root fixture; call
   `model.requestForceKill(launchd)` and expect `killState == nil` and
   `!model.isAwaitingKillConfirmation`.

4. `theModelRefusesToSignalOtherUsersProcesses()` — root fixture; call
   `await model.kill(launchd)` and `await model.forceKill(launchd)` **directly**, bypassing
   the view. Expect `kills.signals.isEmpty` and `model.killStates.isEmpty`. This is the
   test that pins the model-level guard from step 3.

5. `closingThePopoverClearsArmedPromptsButNotKillsInFlight()` — two-row fixture
   (`sampleLsof` + the postgres line, recorder `[42: "node", 7: "postgres"]`, no
   `onSignal` hook so nothing ever exits). Refresh, `await model.kill(sampleListener)` so
   node lands in `.stillRunning`, then `model.requestForceKill(model.listeners[1])` to arm
   postgres. Call `model.stopPolling()`. Expect
   `model.killState(for: sampleListener) == .stillRunning` and
   `model.killState(for: postgres) == nil` and `!model.isAwaitingKillConfirmation`.

Also extend `SquatterTests/SnapshotTests.swift` so the new row state gets rendered. Inside
`rendersListEmptyAndErrorStates()`, immediately after the block that produces
`confirmURL` (the one using `longName` and `confirming.requestKill(victim)`), add:

```swift
        let forcing = await loadedModel(longName, kills: KillRecorder(names: [11: "Adobe Desktop Service"]))
        let forceVictim = try #require(forcing.listeners.first { $0.processName == "Adobe Desktop Service" })
        forcing.requestForceKill(forceVictim)
        let forceConfirmURL = try snapshot(PortListView(model: forcing, settings: SettingsModel(loginItem: FakeLoginItem(), preferences: Preferences(defaults: freshDefaults()))), name: "list-confirm-force-kill")
```

and add `forceConfirmURL` to the array in the final `for url in [...]` loop. The longest
name in the fixture is used deliberately: it is the case where the two buttons are most
likely to truncate.

**Verification**: `xcodebuild -project Squatter.xcodeproj -scheme Squatter -destination 'platform=macOS' test`
→ exit 0, **74 tests** pass (69 existing + 5 new; the snapshot addition lives inside an
existing test and does not change the count).

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `xcodebuild -project Squatter.xcodeproj -scheme Squatter -configuration Debug build` exits 0
- [ ] `xcodebuild -project Squatter.xcodeproj -scheme Squatter -destination 'platform=macOS' test` exits 0 and reports 74 tests
- [ ] `grep -n "await model.forceKill" Squatter/Views/PortRow.swift` returns exactly **two**
      lines — one inside the `.confirmingForce` case of `trailing` (added by step 6) and one
      inside the `.stillRunning` case (pre-existing, and step 5 explicitly requires it to
      stay). *(Corrected 2026-08-28: this criterion previously said "exactly one line",
      which contradicted steps 5 and 6 and describes the half-finished state after step 5.)*
- [ ] `grep -n "model.requestForceKill" Squatter/Views/PortRow.swift` returns exactly one line, inside `menuItems`
- [ ] `grep -c "guard listener.isOwnedByCurrentUser" Squatter/ViewModels/PortListModel.swift` returns `4` (`requestKill`, `requestForceKill`, `kill`, `forceKill`)
- [ ] `grep -c "requestForceKill" SquatterTests/PortListModelTests.swift` is at least `3`
      (tests 1, 2, 3 and 5 all arm through the model). *(Corrected 2026-08-28: this
      criterion previously counted `confirmingForce`, which only the one test that asserts
      the enum case by equality contains — `grep -c` counts matching lines, not occurrences,
      so it read `1` even with all five tests present and passing.)*
- [ ] `git status --porcelain` lists only: `PortListModel.swift`, `PortRow.swift`, `PortListModelTests.swift`, `SnapshotTests.swift`, `PROJECT_SPEC.md`, `TRACKER.md`, `CHANGELOG.md` — and nothing is staged or committed
- [ ] `plans/README.md` status row for 001 updated

## STOP conditions

Stop and report back (do not improvise) if:

- The drift check shows `Squatter/Views/PortRow.swift` or
  `Squatter/ViewModels/PortListModel.swift` changed since `9c7eef2` and the excerpts in
  "Current state" no longer match the live code.
- `menuItems` in `PortRow.swift` already calls `model.requestForceKill` — the bug has been
  fixed independently; report that and make no code change.
- Any existing test fails after step 2, 3 or 4. Those steps are meant to be behaviour-preserving
  for every path already covered; a failure means an assumption here is wrong, not that the
  test needs updating. **Do not edit an existing test to make it pass.**
- Adding `.confirmingForce` forces you to modify a file outside the in-scope list.
- The final test count is anything other than 74.

## Maintenance notes

- **The design decision the owner should review**: this plan *adds a confirmation* to the
  menu's Force Kill rather than *removing* the menu item. Removing it would also satisfy
  the spec — SIGKILL would then only be reachable through the SIGTERM → "Still running" →
  Force Kill flow — and would be less code. It was rejected here because it takes away a
  capability a power user may rely on. If the owner prefers removal, delete the Force Kill
  `Button` from `menuItems`, delete `requestForceKill` and `.confirmingForce`, and keep
  only steps 3 and 4.
- `KillState` now has two "armed" cases and four "in flight" cases. The distinction is
  encoded in exactly one place — `PortListModel.isConfirming(_:)`. Any future state
  (e.g. a `.confirmingBulk`) must be added there too, or Escape will silently stop
  cancelling it.
- A reviewer should check that `cancelAllKillConfirmations()` is still the only thing
  `stopPolling()` clears — clearing `.failed` there too would swallow error messages the
  user has not read yet.
- Deferred out of this plan: `PortListModel.kill(_:)` still does not verify that the row
  was armed before signalling. That is intentional (tests and snapshots call it directly),
  but it means the confirmation is a UI-level contract, not a model-level one. If that
  matters later, the fix is to give `kill(_:)` a `confirmed: Bool = false` parameter rather
  than a state precondition.
