# Plan 010: Let the ignore list be typed into, not just right-clicked into

> **Notion tracking — 2026-09-06:** Current task tracking is in Notion: [Squatter](https://app.notion.com/p/3d3cacb0997081acbbbbfc2bd0f0ddf8), [Tasks](https://app.notion.com/p/3d2cacb09970808d99b7f3c0c0a36f35). Any Linear URLs, IDs, statuses or refusals below are historical references. Resolve migrated IDs via `Linear ID` and verify `Project`; use the Notion task page for all new updates. This supersedes instructions below to create, query, update or close Linear issues. Follow the current repository tracking rule, including its owner-review requirements.

> **Executor instructions**: Follow this plan step by step. Run every verification
> command and confirm the expected result before moving to the next step. If anything
> in the "STOP conditions" section occurs, stop and report — do not improvise. When
> done, update the status row for this plan in `plans/README.md`.
>
> **Drift check (run first)**:
> `git diff --stat 947e97c..HEAD -- Squatter/ViewModels/PortListModel.swift Squatter/Views/SettingsView.swift`
> If either changed since this plan was written, compare the "Current state" excerpts against
> the live code before proceeding; on a mismatch, STOP.

## Status

- **Priority**: P3
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none, but **land after `plans/009-hide-ports-above-a-threshold.md`** if
  both are being executed — they edit adjacent regions of `SettingsView.swift`.
- **Category**: direction (new feature)
- **Planned at**: commit `947e97c`, 2026-08-29

## Why this matters

A port can only be added to the ignore list by right-clicking a row that is currently
visible in the list. That means the one moment you cannot ignore a port is when it is not
listening — so a user who knows they never want to see 7000 (macOS AirPlay Receiver, which
appears and disappears) has to wait for it to show up before they can silence it. There is
also no way to paste in a set of ports they already know they want gone.

The Settings "Ignored" section already lists and removes entries; it just cannot add them.
This plan adds one text field that accepts ports separated by commas, newlines, or spaces,
and reports which tokens it skipped rather than silently discarding them.

## Current state

### The ignore API — `Squatter/ViewModels/PortListModel.swift:294-330`

```swift
    private(set) var ignoredPorts: Set<UInt16>
    private(set) var ignoredProcessNames: Set<String>
...
    func ignorePort(of listener: Listener) {
        ignoredPorts.insert(listener.port)
        preferences.ignoredPorts = ignoredPorts
        clearSelectionIfHidden()
    }
...
    func removeIgnoredPort(_ port: UInt16) {
        ignoredPorts.remove(port)
        preferences.ignoredPorts = ignoredPorts
    }
```

Every mutator follows the same three beats: change the set, write it back through
`preferences`, then fix the selection if the current row just disappeared. Your new method
must do the same. `ignoredPorts` is `private(set)`, so the view cannot mutate it directly —
that is deliberate and must stay.

### The Settings section — `Squatter/Views/SettingsView.swift:67-78`

```swift
            if !model.ignoredPorts.isEmpty || !model.ignoredProcessNames.isEmpty {
                Section("Ignored") {
                    ForEach(model.ignoredPorts.sorted(), id: \.self) { port in
                        ignoredRow(Text("Port \(String(port))")) { model.removeIgnoredPort(port) }
                    }
                    ForEach(model.ignoredProcessNames.sorted(), id: \.self) { name in
                        ignoredRow(Text(name)) { model.removeIgnoredProcessName(name) }
                    }
                }
            }
```

Note the whole section is conditional on the list being non-empty — which is exactly the
state in which a user most wants to add the first entry. That condition has to go.

`SettingsView` already holds view-local `@State` elsewhere in the file's sibling
(`PortListView.isShowingSettings`), so a `@State` draft string is consistent with the
codebase. The rule *"views hold no logic"* (`AGENTS.md`) means the **parsing** belongs in
the model — an in-progress text field is view state.

### Conventions this plan must honor

- `rules/ux-writing.md`: **Title Case** for buttons ("Add Ports" — verb + object, never a
  bare "Add"); **sentence case** for the field's placeholder, the footer, and any error;
  errors say what failed and what to do next; *"Never prefill URL fields — scheme hints go in
  `placeholder` only"* (the spirit here: the field starts empty, the hint is the placeholder).
- `rules/ios-swift.md`: all user-facing strings via `String(localized:)`; SF Symbols on
  buttons; no force-unwraps.
- **Do not commit, do not push, do not touch Linear.**

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Build | `xcodebuild -project Squatter.xcodeproj -scheme Squatter -configuration Debug build` | `** BUILD SUCCEEDED **` |
| Test | `xcodebuild -project Squatter.xcodeproj -scheme Squatter -destination 'platform=macOS' test` | `** TEST SUCCEEDED **` |

**Baseline: 84 tests in 9 suites pass at `947e97c`** (higher if earlier plans landed). This
plan adds no files, so `xcodegen generate` is not needed.

## Scope

**In scope**:
- `Squatter/ViewModels/PortListModel.swift`
- `Squatter/Views/SettingsView.swift`
- `SquatterTests/PortListModelTests.swift`, `SquatterTests/SnapshotTests.swift`
- `TRACKER.md`, `CHANGELOG.md`

**Out of scope**:
- Typing **process names** into the ignore list. Ports only — a free-text process-name field
  invites typos that silently hide nothing, and nobody asked for it.
- `Squatter/Model/Preferences.swift` — `ignoredPorts` already round-trips and already drops
  invalid values on read (`SquatterTests/PortListModelTests.swift:542`,
  `ignoreListsRoundTripAndDropInvalidPorts`). No storage change is needed.
- Import/export of the whole list, or a comma-separated single-field editor that replaces the
  rows. The rows-plus-add-field shape is strictly better than the reference app's free-text
  blob, and this plan keeps it.
- `Squatter/Views/PortRow.swift` and the right-click Ignore items — unchanged.

## Steps

### Step 1: Parse in the model, not the view

In `Squatter/ViewModels/PortListModel.swift`, in the "Ignore list" section, add:

```swift
    /// Result of adding typed ports: what was added, and the tokens that were not ports.
    struct AddedPorts: Equatable, Sendable {
        var added: Set<UInt16> = []
        var skipped: [String] = []
    }

    /// Adds every port in `text` to the ignore list. Accepts commas, newlines, spaces and
    /// tabs as separators, so a pasted list works as-is. Tokens that are not a port in
    /// 1…65535 are returned in `skipped` rather than silently dropped.
    @discardableResult
    func addIgnoredPorts(from text: String) -> AddedPorts {
        var result = AddedPorts()
        let separators = CharacterSet(charactersIn: ",;\n\t ")
        for token in text.components(separatedBy: separators) {
            let trimmed = token.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            guard let port = UInt16(trimmed), port > 0 else {
                result.skipped.append(trimmed)
                continue
            }
            result.added.insert(port)
        }
        guard !result.added.isEmpty else { return result }
        ignoredPorts.formUnion(result.added)
        preferences.ignoredPorts = ignoredPorts
        clearSelectionIfHidden()
        return result
    }
```

`UInt16(trimmed)` rejects `"abc"`, `"99999"`, `"-1"`, `"3000.0"` and `"1e3"` on its own —
that is why the parse is `UInt16.init` and not `Int` plus a range check. Do not replace it.

**Verify**: build → `** BUILD SUCCEEDED **`;
`grep -n 'ignoredPorts.formUnion' Squatter/ViewModels/PortListModel.swift` → one match, and
`grep -n 'private(set) var ignoredPorts' Squatter/ViewModels/PortListModel.swift` → still
`private(set)`.

### Step 2: Add the field to Settings

In `Squatter/Views/SettingsView.swift`:

Add two `@State` properties at the top of the struct, beside `@Bindable var model`:

```swift
    @State private var portsToAdd = ""
    /// Tokens the last submission could not read as ports, echoed back so nothing is
    /// silently dropped.
    @State private var skippedPorts: [String] = []
```

Replace the conditional `if !model.ignoredPorts.isEmpty || … { Section("Ignored") { … } }`
with an **unconditional** section whose first row is the field:

```swift
            Section {
                LabeledContent("Ignore these ports") {
                    HStack(spacing: 6) {
                        TextField(String(localized: "3000, 5173"), text: $portsToAdd)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 120)
                            .onSubmit(addPorts)
                        Button("Add Ports", systemImage: "plus") { addPorts() }
                            .labelStyle(.iconOnly)
                            .controlSize(.small)
                            .disabled(portsToAdd.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                if !skippedPorts.isEmpty {
                    Text("Skipped \(skippedPorts.joined(separator: ", ")) — a port is a number from 1 to 65535.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                ForEach(model.ignoredPorts.sorted(), id: \.self) { port in
                    ignoredRow(Text("Port \(String(port))")) { model.removeIgnoredPort(port) }
                }
                ForEach(model.ignoredProcessNames.sorted(), id: \.self) { name in
                    ignoredRow(Text(name)) { model.removeIgnoredProcessName(name) }
                }
            } header: {
                Text("Ignored")
            } footer: {
                Text("Separate ports with a comma, a space, or a new line. Right-click any row in the list to ignore it by process name.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
```

and add the private helper beside `ignoredRow` / `intervalLabel`:

```swift
    private func addPorts() {
        let result = model.addIgnoredPorts(from: portsToAdd)
        skippedPorts = result.skipped
        // Keep only what could not be read, so the user can fix it in place.
        portsToAdd = result.skipped.joined(separator: ", ")
    }
```

The button label uses `.labelStyle(.iconOnly)` so the row stays narrow in a 320 pt window,
while the accessible name stays "Add Ports" — that is why it is a `Button(_:systemImage:)`
and not a bare `Image`.

**Verify**: build → `** BUILD SUCCEEDED **`;
`grep -n 'if !model.ignoredPorts.isEmpty' Squatter/Views/SettingsView.swift` → **no matches**
(the section is unconditional now).

### Step 3: Tests

In `SquatterTests/PortListModelTests.swift` (patterns: `ignoringAPortHidesItAndCountsIt`
line 143, `ignoreListPersistsAcrossModels` line 170):

1. `typedPortsAreAddedAndNormalised` — `addIgnoredPorts(from: "3000, 5173\n8080 9090")`
   returns `added == [3000, 5173, 8080, 9090]`, `skipped == []`, and
   `model.ignoredPorts` contains all four.
2. `invalidTokensAreReportedNotSwallowed` — `"3000, abc, 99999, 0, -1, 3000.5"` adds only
   `3000` and reports `skipped == ["abc", "99999", "0", "-1", "3000.5"]` in that order.
3. `emptyInputChangesNothing` — `"   ,,\n "` returns an empty `AddedPorts` and leaves
   `ignoredPorts` untouched (assert the set is identical before and after).
4. `typedPortsHideMatchingRowsImmediately` — over an lsof string with 3000 and 5432, adding
   `"3000"` drops the row from `filtered` and makes `hiddenCount == 1`.
5. `typedPortsPersistAcrossModels` — add through one model, build a second model on the same
   `UserDefaults` suite, expect the same `ignoredPorts`.
6. `addingASelectedPortClearsTheSelection` — select the 3000 row, add `"3000"`, expect
   `selection == nil`.
7. `duplicatesAreIdempotent` — adding `"3000"` twice leaves `ignoredPorts.count` at 1 and the
   second call still reports it in `added`.

**Verify**: test command → `** TEST SUCCEEDED **`, 7 new tests.

### Step 4: Snapshot

In `SquatterTests/SnapshotTests.swift`, the existing `settings` snapshot already renders
`SettingsView` with a model that has ignored entries. Confirm the new field appears there and
does not clip at 320 pt: run the test, open the PNG printed after `SNAPSHOTS:`, and check the
"Ignore these ports" row, its placeholder and the + button are all fully visible.

**Verify**: test command → `** TEST SUCCEEDED **`; PNG inspected by eye.

### Step 5: Docs

- `TRACKER.md` — dated entry: the field, comma/space/newline separators, and that skipped
  tokens are echoed back into the field rather than dropped.
- `CHANGELOG.md` `[Unreleased]` → **Added**, e.g. *"You can now type ports straight into the
  ignore list in Settings — separate them with commas, spaces, or new lines — instead of
  waiting for a port to appear in the list so you can right-click it."*

**Verify**: `git status --short` lists only in-scope files.

## Done criteria

ALL must hold:

- [ ] Build → `** BUILD SUCCEEDED **`
- [ ] Test → `** TEST SUCCEEDED **`, ≥ 7 new tests, zero failures
- [ ] `grep -n 'private(set) var ignoredPorts' Squatter/ViewModels/PortListModel.swift` →
      still `private(set)` (the view never mutates the set directly)
- [ ] `grep -c 'UInt16(' Squatter/Views/SettingsView.swift` → `0` (parsing stayed in the model)
- [ ] The "Ignored" section renders with an empty ignore list (verified in the snapshot)
- [ ] A test asserts `"99999"` is reported as skipped rather than silently dropped
- [ ] `TRACKER.md` and `CHANGELOG.md` updated
- [ ] Nothing committed, nothing pushed, no Linear issue touched
- [ ] `plans/README.md` status row for 010 updated

## STOP conditions

Stop and report if:

- `SettingsView.swift` no longer matches the excerpt above — most likely because plan 009
  landed and moved the sections around. Re-read the file and place the new section after
  whatever the last non-About section now is, rather than pattern-matching blindly.
- A test proves the ignore list can be corrupted from the field (e.g. `0` or `65536` reaching
  `UserDefaults`). Report it — that would mean the `UInt16` parse was replaced.
- You want to add process-name entry to the same field. It is out of scope; report the idea
  instead of building it.

## Maintenance notes

- The parse accepts `;` as a separator too, which nobody asked for but costs nothing and
  covers a paste from a config file. If separators ever need to be documented to users, the
  footer is the only place they are described.
- `addIgnoredPorts(from:)` returns its result instead of storing an error on the model on
  purpose: the message belongs to one text field in one view, and putting it on the
  `@Observable` model would make it outlive the popover that produced it.
- Watch in review: that `portsToAdd` is reset to *only* the skipped tokens. Clearing it
  entirely loses the user's typo before they can see what was wrong with it, and leaving it
  whole re-adds everything on the next Return.
- Deferred: a port **range** syntax (`3000-3010`). Today that token is reported as skipped,
  which is honest. If it is ever added, `AddedPorts.skipped` is where the behaviour changes.
