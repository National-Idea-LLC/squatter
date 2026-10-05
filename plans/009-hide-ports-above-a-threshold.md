# Plan 009: Hide ports above a threshold with one switch

> **Notion tracking — 2026-09-06:** Current task tracking is in Notion: [Squatter](https://app.notion.com/p/3d3cacb0997081acbbbbfc2bd0f0ddf8), [Tasks](https://app.notion.com/p/3d2cacb09970808d99b7f3c0c0a36f35). Any Linear URLs, IDs, statuses or refusals below are historical references. Resolve migrated IDs via `Linear ID` and verify `Project`; use the Notion task page for all new updates. This supersedes instructions below to create, query, update or close Linear issues. Follow the current repository tracking rule, including its owner-review requirements.

> **Executor instructions**: Follow this plan step by step. Run every verification
> command and confirm the expected result before moving to the next step. If anything
> in the "STOP conditions" section occurs, stop and report — do not improvise. When
> done, update the status row for this plan in `plans/README.md`.
>
> **Drift check (run first)**:
> `git diff --stat 947e97c..HEAD -- Squatter/Model/Preferences.swift Squatter/ViewModels/PortListModel.swift Squatter/Views/SettingsView.swift Squatter/Views/PortRow.swift`
> If any changed since this plan was written, compare the "Current state" excerpts against
> the live code before proceeding; on a mismatch, STOP.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: LOW
- **Depends on**: none (independent of plans 007 and 008)
- **Category**: direction (new feature)
- **Planned at**: commit `947e97c`, 2026-08-29

## Why this matters

On a normal Mac, most of what `lsof` reports is noise the user will never act on: macOS
daemons and helper processes listening on high, effectively random ports. Squatter's only
tool against this today is the per-port ignore list, which means right-clicking about
fifteen rows one at a time, and doing it again whenever a daemon picks a different port —
which is exactly what ephemeral high ports do.

Dev servers live low: 3000, 5173, 8080, 5432, 8000. A single switch that hides everything
above a threshold cuts the list to the rows a developer actually cares about, in one click,
permanently. This is the highest-leverage noise control the app can offer, and the reference
app ships the same idea as a fixed "Ignore ports 10000+" checkbox. Squatter's version makes
the number editable and defaults the whole rule to **off**, so nobody's list silently loses
rows after an update.

## Current state

### Ignoring today — `Squatter/ViewModels/PortListModel.swift`

One predicate drives everything: the filter, the group split, the footer count, the row
dimming, the LED colour, and the context menu.

```swift
    func isIgnored(_ listener: Listener) -> Bool {
        ignoredPorts.contains(listener.port) || ignoredProcessNames.contains(listener.processName)
    }

    /// How many current listeners the ignore list hides (independent of the text filter).
    var hiddenCount: Int { listeners.count(where: isIgnored) }
```

Its five callers, all of which keep working unchanged if you extend the predicate:

- `filtered` — `guard showIgnored || !isIgnored(listener) else { return false }`
- `groups` — `if isIgnored(listener) { ignored.append(listener) }`
- `hiddenCount` — the "N ignored" status-bar button and the "Everything is ignored." state
- `PortRow.isIgnored` — dimming and the LED's `.primary.opacity(0.15)`
- `PortRow.menuItems` — shows **Unignore** when ignored, the two **Ignore …** items otherwise

The undo path is list-based, and this is the trap in this plan:

```swift
    /// Removes every rule that hides this listener (its port and its process name).
    func unignore(_ listener: Listener) {
        removeIgnoredPort(listener.port)
        removeIgnoredProcessName(listener.processName)
    }
```

If a threshold rule simply makes `isIgnored` return `true`, then **Unignore** appears on a
high-port row, the user clicks it, and nothing happens — the row is hidden by a rule, not by
a list entry, so removing list entries changes nothing. A dead menu item is worse than no
menu item. Step 3 solves this by making the *reason* explicit and giving the threshold its
own undo.

### Preferences today — `Squatter/Model/Preferences.swift:4-10, 30-37`

```swift
enum DefaultsKeys {
    static let refreshInterval = "squatter.refreshInterval"
    static let showCountInMenuBar = "squatter.showCountInMenuBar"
    static let ignoredPorts = "squatter.ignoredPorts"
    static let ignoredProcessNames = "squatter.ignoredProcessNames"
    static let sortOrder = "squatter.sortOrder"
}
...
    /// Seconds between automatic scans while the popover is open. Clamped to a sane range.
    var refreshInterval: TimeInterval {
        get {
            let stored = defaults.double(forKey: DefaultsKeys.refreshInterval)
            return stored > 0 ? min(max(stored, 0.5), 60) : Self.defaultRefreshInterval
        }
        nonmutating set { defaults.set(newValue, forKey: DefaultsKeys.refreshInterval) }
    }
```

`refreshInterval` is the pattern to copy for a clamped numeric preference with a default:
an unset key reads as the default, and out-of-range values are clamped on read rather than
trusted.

### Settings today — `Squatter/Views/SettingsView.swift:28-45`

```swift
            Section {
                Toggle("Show count in menu bar", isOn: $model.showCountInMenuBar)
                Picker("Sort by", selection: $model.sortOrder) { ... }
                Picker("Refresh every", selection: $settings.refreshInterval) { ... }
            } footer: {
                Text(model.showCountInMenuBar ? ... : ...)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
```

The window is `.frame(width: 320, height: 480)` and the form scrolls, so a new section is safe.

### Conventions this plan must honor

- `rules/ios-swift.md`: *"UserDefaults keys: prefix `squatter.`, define once in a
  `DefaultsKeys` enum, never rename shipped keys without a migration"*; all user-facing
  strings through `String(localized:)`; SF Symbols on every menu item; `switch` exhaustive
  without `default`.
- `rules/ux-writing.md`: **Title Case** for buttons and menu items; **sentence case** for
  settings labels, footers, tooltips and accessibility labels.
- **Do not commit, do not push, do not touch Linear.**
- `TRACKER.md` on every change; `CHANGELOG.md` too — users will notice this one.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Build | `xcodebuild -project Squatter.xcodeproj -scheme Squatter -configuration Debug build` | `** BUILD SUCCEEDED **` |
| Test | `xcodebuild -project Squatter.xcodeproj -scheme Squatter -destination 'platform=macOS' test` | `** TEST SUCCEEDED **` |
| Regenerate project | `xcodegen generate` | only needed if you add a file — this plan adds none |

**Baseline: 84 tests in 9 suites pass at commit `947e97c`** (higher if plans 007/008 landed
first). No previously-passing test may fail.

## Scope

**In scope**:
- `Squatter/Model/Preferences.swift`
- `Squatter/ViewModels/PortListModel.swift`
- `Squatter/Views/SettingsView.swift`
- `Squatter/Views/PortRow.swift`
- `SquatterTests/PortListModelTests.swift`, `SquatterTests/SnapshotTests.swift`
- `TRACKER.md`, `CHANGELOG.md`, `PROJECT_SPEC.md`

**Out of scope**:
- `Squatter/Services/*` — this is entirely a filtering concern above the scanner. The
  scanner keeps returning every listener; hiding happens in the model.
- `Squatter/Views/PortListView.swift` — the "N ignored" button, the `showIgnored` toggle and
  the "Everything is ignored." state already read `hiddenCount` and need no change. If you
  find yourself editing this file, you have taken a wrong turn.
- The text filter. A user typing `54321` while the rule hides it is a real question, and the
  answer chosen here is "the rule wins, and the footer says how many are hidden" — same as
  the existing ignore list. Do not special-case the filter.
- Renaming `isIgnored`, `hiddenCount`, `showIgnored`, or the "Ignored" group header. The
  threshold is a new *reason* for an existing concept, not a new concept.

## Steps

### Step 1: Add the two preferences

In `Squatter/Model/Preferences.swift`, add to `DefaultsKeys`:

```swift
    static let hideHighPorts = "squatter.hideHighPorts"
    static let highPortThreshold = "squatter.highPortThreshold"
```

and to `Preferences`:

```swift
    static let defaultHighPortThreshold: UInt16 = 10_000

    /// Off by default: an update must never make rows vanish from someone's list without
    /// them asking.
    var hideHighPorts: Bool {
        get { defaults.bool(forKey: DefaultsKeys.hideHighPorts) }
        nonmutating set { defaults.set(newValue, forKey: DefaultsKeys.hideHighPorts) }
    }

    /// Ports strictly above this are hidden while `hideHighPorts` is on. Clamped on read,
    /// like `refreshInterval`, so a hand-edited plist can't hide everything.
    var highPortThreshold: UInt16 {
        get {
            let stored = defaults.integer(forKey: DefaultsKeys.highPortThreshold)
            guard stored > 0 else { return Self.defaultHighPortThreshold }
            return UInt16(min(max(stored, 1), 65_535))
        }
        nonmutating set { defaults.set(Int(newValue), forKey: DefaultsKeys.highPortThreshold) }
    }
```

**Verify**: `grep -c 'squatter\.' Squatter/Model/Preferences.swift` → 7 (5 existing + 2 new;
9 if plan 007 landed first). Build → `** BUILD SUCCEEDED **`.

### Step 2: Name the reason a row is hidden

In `Squatter/ViewModels/PortListModel.swift`, add near `ListenerGroup`:

```swift
/// Why a row is hidden. The threshold is a rule, not a list entry, so the row's undo
/// action differs — see `PortRow.menuItems`.
enum IgnoreReason: Equatable, Sendable {
    case port
    case processName
    case highPort
}
```

Replace `isIgnored` with a reason-returning function, keeping `isIgnored` as a thin wrapper
so its five existing callers keep compiling and reading well:

```swift
    /// Why this listener is hidden, or `nil` when it is not.
    /// Order matters: an explicit list entry outranks the threshold rule, so a port the user
    /// ignored by hand still offers Unignore even when the rule would also hide it.
    func ignoreReason(_ listener: Listener) -> IgnoreReason? {
        if ignoredPorts.contains(listener.port) { return .port }
        if ignoredProcessNames.contains(listener.processName) { return .processName }
        if hideHighPorts, listener.port > highPortThreshold { return .highPort }
        return nil
    }

    func isIgnored(_ listener: Listener) -> Bool { ignoreReason(listener) != nil }
```

Add the two observable properties beside the existing `sortOrder` / `showCountInMenuBar`
(which use exactly this `didSet` shape):

```swift
    /// Hide ports above `highPortThreshold` — most of them are macOS background services.
    var hideHighPorts: Bool {
        didSet {
            preferences.hideHighPorts = hideHighPorts
            clearSelectionIfHidden()
        }
    }

    var highPortThreshold: UInt16 {
        didSet {
            preferences.highPortThreshold = highPortThreshold
            clearSelectionIfHidden()
        }
    }
```

Initialise both from `preferences` in `init`, next to `self.sortOrder = preferences.sortOrder`.

Add one intent for the row menu's undo:

```swift
    /// Turns the whole threshold rule off — the undo for a row hidden by `.highPort`,
    /// which no list removal can reveal.
    func stopHidingHighPorts() { hideHighPorts = false }
```

`clearSelectionIfHidden()` already exists (private, at the end of the "Ignore list" section)
and does the right thing; reuse it rather than writing another.

**Verify**: build → `** BUILD SUCCEEDED **`;
`grep -n 'func isIgnored' Squatter/ViewModels/PortListModel.swift` → one match, and
`grep -c 'isIgnored' Squatter/ViewModels/PortListModel.swift Squatter/Views/PortRow.swift`
→ unchanged call sites still compile.

### Step 3: Give the row the right undo

In `Squatter/Views/PortRow.swift`, `menuItems` currently ends:

```swift
        if isIgnored {
            Button("Unignore", systemImage: "eye") { model.unignore(listener) }
        } else {
            Button(String(localized: "Ignore Port \(String(listener.port))"), systemImage: "eye.slash") {
                model.ignorePort(of: listener)
            }
            Button(String(localized: "Ignore \(listener.processName)"), systemImage: "eye.slash") {
                model.ignoreProcess(of: listener)
            }
        }
```

Branch on the reason instead, with an exhaustive `switch` (no `default`):

```swift
        switch model.ignoreReason(listener) {
        case .port, .processName:
            Button("Unignore", systemImage: "eye") { model.unignore(listener) }
        case .highPort:
            // Unignore would be a dead button here: this row is hidden by a rule, and no
            // list removal reveals it. Offer the rule's own undo instead.
            Button(String(localized: "Show Ports Above \(String(model.highPortThreshold))"), systemImage: "eye") {
                model.stopHidingHighPorts()
            }
        case nil:
            Button(String(localized: "Ignore Port \(String(listener.port))"), systemImage: "eye.slash") { ... }
            Button(String(localized: "Ignore \(listener.processName)"), systemImage: "eye.slash") { ... }
        }
```

Everything else in `PortRow` stays as it is — `isIgnored` still drives dimming and the LED.

**Verify**: build → `** BUILD SUCCEEDED **`;
`grep -n 'default:' Squatter/Views/PortRow.swift` → only the pre-existing one inside
`confirmationPrompt`.

### Step 4: Add the setting

In `Squatter/Views/SettingsView.swift`, add a new `Section` immediately **after** the section
containing "Show count in menu bar" and **before** the "About" section:

```swift
            Section {
                Toggle("Hide high ports", isOn: $model.hideHighPorts)
                LabeledContent("Hide ports above") {
                    TextField(
                        "",
                        value: $model.highPortThreshold,
                        format: .number.grouping(.never)
                    )
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 64)
                    .disabled(!model.hideHighPorts)
                }
            } footer: {
                Text("Most ports above 10,000 belong to macOS background services, not to your dev servers. Hidden rows are counted next to the eye in the list.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
```

Sentence case throughout, per `rules/ux-writing.md`. The `format:` overload is what keeps the
field numeric without hand-rolled parsing; the clamp in `Preferences.highPortThreshold`
catches anything absurd that still gets through.

**Verify**: build → `** BUILD SUCCEEDED **`, and the settings snapshot from step 6 shows
both controls with the number field greyed out while the toggle is off.

### Step 5: Model tests

In `SquatterTests/PortListModelTests.swift` (patterns: `ignoringAPortHidesItAndCountsIt`
line 143, `textFilterAndIgnoreCompose` line 191, `defaultsAndRoundTrip` line 522). The
existing `makeModel` helper takes a `runner:` — build lsof strings the way those tests do,
e.g. `sampleLsof + "p9\ncmDNSResponder\nu501\nf1\nPTCP\nn*:52398\nTST=LISTEN\n"`.

1. `hideHighPortsIsOffByDefault` — a fresh model over a list containing 3000 and 52398 shows
   both, and `hiddenCount == 0`.
2. `thresholdHidesPortsStrictlyAbove` — with `hideHighPorts = true` and
   `highPortThreshold = 10_000`: a listener on **10000 is still shown**, one on **10001 is
   hidden**. Assert both — "above" means `>`, and this test is the contract.
3. `hiddenHighPortsAreCountedAndRevealable` — `hiddenCount == 1`, and setting
   `showIgnored = true` puts the row in the `.ignored` group.
4. `explicitIgnoreOutranksTheThreshold` — a port that is both in `ignoredPorts` and above the
   threshold reports `ignoreReason == .port` (so the row still offers Unignore).
5. `stopHidingHighPortsRevealsEverything` — after `stopHidingHighPorts()`, `hiddenCount == 0`
   and `preferences.hideHighPorts == false` in a fresh `Preferences` over the same defaults.
6. `thresholdPersistsAcrossModels` — set both on one model, build a second model on the same
   `UserDefaults` suite, and expect the same visible list (mirrors
   `ignoreListPersistsAcrossModels`, line 170).
7. `thresholdIsClampedOnRead` — write `0` and `999_999` directly into the defaults suite and
   expect `10_000` and `65_535` respectively.
8. `selectionClearsWhenTheThresholdHidesIt` — select the 52398 row, turn the rule on, expect
   `selection == nil`.
9. `menuBarCountExcludesHighPorts` — with the badge on and the rule on, `menuBarCount`
   counts only visible rows.

**Verify**: test command → `** TEST SUCCEEDED **`, 9 new tests (93 total from the 84 baseline).

### Step 6: Snapshot

In `SquatterTests/SnapshotTests.swift`, inside `rendersListEmptyAndErrorStates`: build a
model over an lsof string containing at least one high port, set `hideHighPorts = true`,
`showIgnored = true`, and snapshot as `"list-high-ports"`. Also re-snapshot `"settings"`
with `hideHighPorts = true` so the new section is visible (the existing `settings` snapshot
call already exists near the end of that test — pass the model that has the rule on). Add
any new URL to the size-check loop.

Open both PNGs: the high-port row must be dimmed and grouped under "Ignored", and the
settings section must not clip the number field.

**Verify**: test command → `** TEST SUCCEEDED **`; PNGs inspected by eye.

### Step 7: Docs

- `TRACKER.md` — dated entry under `## Dev changelog`, newest first. Say why the rule is off
  by default and why `.highPort` gets its own undo instead of reusing Unignore.
- `CHANGELOG.md` `[Unreleased]` → **Added**, user-facing, e.g. *"A new setting hides ports
  above a number you choose — 10,000 by default — so the list shows your dev servers instead
  of macOS background services."*
- `PROJECT_SPEC.md` — the P1 **Ignore list** bullet describes only the per-port/per-process
  list. Add the threshold rule beside it so the spec matches the app.

**Verify**: `git status --short` lists only in-scope files.

## Done criteria

ALL must hold:

- [ ] Build → `** BUILD SUCCEEDED **` (warnings are errors: `SWIFT_TREAT_WARNINGS_AS_ERRORS: YES`)
- [ ] Test → `** TEST SUCCEEDED **`, ≥ 9 new tests, zero failures
- [ ] `grep -n 'squatter.hideHighPorts\|squatter.highPortThreshold' Squatter/Model/Preferences.swift`
      → both keys defined exactly once, in `DefaultsKeys`
- [ ] `grep -rn 'hideHighPorts\|highPortThreshold' Squatter/Views/PortListView.swift` → no
      matches (that file needed no change)
- [ ] `grep -rn '10000\|10_000' Squatter/Views/` → no matches (the threshold reaches the UI
      through the model, never as a literal)
- [ ] A test asserts port 10000 visible and 10001 hidden at threshold 10000
- [ ] The `list-high-ports` and `settings` snapshots inspected by eye
- [ ] `TRACKER.md`, `CHANGELOG.md`, `PROJECT_SPEC.md` updated
- [ ] Nothing committed, nothing pushed, no Linear issue touched
- [ ] `plans/README.md` status row for 009 updated

## STOP conditions

Stop and report if:

- The drift check shows `PortListModel.swift` changed since `947e97c` and `isIgnored` no
  longer looks like the excerpt above.
- Extending `isIgnored` breaks a test you cannot fix without changing that test's intent.
  Existing ignore tests must all still pass **unmodified** — the rule is off by default
  precisely so they do.
- You conclude the threshold should also apply to the text filter (typing an exact hidden
  port number). Report the question instead of deciding it; it is a product call for the
  owner.
- The `TextField(value:format:)` binding fights you (e.g. the field clears while typing).
  Report what you saw rather than replacing it with a hand-rolled `String` binding and a
  parser — that path is how the number field ends up accepting `"1e9"`.

## Maintenance notes

- The `IgnoreReason` enum is the extension point: any future rule ("hide loopback-only
  ports", "hide root-owned") adds a case and a matching undo in `PortRow.menuItems`, and the
  compiler will point at every place that must decide what to do about it.
- `hiddenCount` now mixes list entries and rule matches under one "N ignored" label. If that
  ever reads as misleading, the honest fix is separate counts in the status bar, not a
  reworded label.
- Watch in review: that an *explicitly* ignored port above the threshold still offers
  Unignore. The ordering inside `ignoreReason` is the whole reason that works, and a
  future refactor that sorts those checks differently silently breaks it.
- Deferred on purpose: a lower bound ("hide ports below N"), per-process thresholds, and
  presets ("only show 3000/5173/8080"). None were asked for.
