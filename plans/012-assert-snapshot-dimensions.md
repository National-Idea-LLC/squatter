# Plan 012: Make the snapshot tests assert rendered dimensions, so they can fail

> **Notion tracking — 2026-09-06:** Current task tracking is in Notion: [Squatter](https://app.notion.com/p/3d3cacb0997081acbbbbfc2bd0f0ddf8), [Tasks](https://app.notion.com/p/3d2cacb09970808d99b7f3c0c0a36f35). Any Linear URLs, IDs, statuses or refusals below are historical references. Resolve migrated IDs via `Linear ID` and verify `Project`; use the Notion task page for all new updates. This supersedes instructions below to create, query, update or close Linear issues. Follow the current repository tracking rule, including its owner-review requirements.

> **Executor instructions**: Follow this plan step by step. Run every verification
> command and confirm the expected result before moving to the next step. If anything
> in the "STOP conditions" section occurs, stop and report — do not improvise. When
> done, update the status row for this plan in `plans/README.md` — unless a reviewer
> dispatched you and told you they maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat 02b3a9c..HEAD -- SquatterTests/SnapshotTests.swift Squatter/Views/SettingsView.swift`
> If either changed since this plan was written, compare the "Current state" excerpts against
> the live code before proceeding; on a mismatch, STOP.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: tests
- **Planned at**: commit `02b3a9c`, 2026-08-29

## Why this matters

The snapshot suite cannot fail. Every PNG it renders is guarded by one assertion — the file
is larger than 1,000 bytes ("looks blank"). On 2026-08-29 that check passed against a
completely broken settings layout: the `Form` closed early, `.formStyle`/`.frame` attached
to the wrong view, and the settings window rendered **320x3294** ungrouped instead of the
fixed **320x480** it is supposed to be. A human opening the image caught it; the suite did
not. As written, the snapshot layer proves a render *happened*, not that it rendered the
right thing.

This plan makes each snapshot assert the rendered image's actual pixel dimensions against
the size it was asked to render at, so a view that escapes its frame fails the test loudly
and names which snapshot broke. The byte check stays — dimensions and non-blankness catch
different failures. The plan is not done until you have *watched the new assertion fail* on
a deliberately oversized view and then reverted the bait: a dimension assertion that has
only ever passed proves nothing, which is the entire point of this plan.

## Current state

### The relevant files

- `SquatterTests/SnapshotTests.swift` — the whole snapshot suite: one helper, one `@Test`,
  twelve snapshots, one byte-count loop. The only file you will change (plus `TRACKER.md`).
- `Squatter/Views/SettingsView.swift` — source of truth for the settings window's fixed
  size (read-only for this plan).
- `PROJECT_SPEC.md:116` — *"Fixed popover size ≈ 360 × 440 pt; list scrolls."* The spec
  fixes the popover; the settings window's exact fixed size lives in code (next excerpt).

### The fixed settings size — `Squatter/Views/SettingsView.swift:132-133`

```swift
        .formStyle(.grouped)
        .frame(width: 320, height: 480) // fixed; the form scrolls when the ignore list grows
```

**320x480 points** is the number the settings snapshot must be held to. Do not assume any
other value; if this line no longer reads exactly this way, STOP (drift).

### The helper that renders every snapshot — `SquatterTests/SnapshotTests.swift:13-31`

```swift
    private func snapshot<V: View>(_ view: V, name: String, size: CGSize = CGSize(width: 360, height: 460), dark: Bool = false) throws -> URL {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        // Key the window: inactive windows render selection and prominent buttons in grey,
        // which hides exactly the contrast problems these snapshots exist to catch.
        window.makeKeyAndOrderFront(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let png = try #require(rep.representation(using: .png, properties: [:]))
```

Note the rep is taken **in `host.bounds`**, not in the requested `size` — that is why the
broken settings layout produced a 320x3294 PNG: the bounds had escaped, and nothing compared
them to `size`.

### The misleading doc comment — `SquatterTests/SnapshotTests.swift:7-8`

```swift
/// Renders the popover in a real (offscreen) window and writes PNGs for eyeballing.
/// Not an assertion on pixels — a build-time sanity check that the views lay out.
```

After this plan, "not an assertion on pixels" is false. Step 1 rewrites it.

### The settings snapshot renders at the wrong size — `SquatterTests/SnapshotTests.swift:104`

```swift
        let settingsURL = try snapshot(SettingsView(settings: settings, model: ignoring).frame(width: 320), name: "settings", size: CGSize(width: 320, height: 560))
```

It asks for 320x**560** while the view fixes itself at 320x**480** — today nothing checks
either number, so nobody noticed. Once the helper asserts dimensions, this call must request
the real fixed size or it will fail for the wrong reason.

### The only assertion in the suite — `SquatterTests/SnapshotTests.swift:121-124`

```swift
        for url in [listURL, darkURL, stubbornURL, confirmURL, forceConfirmURL, emptyURL, errorURL, ignoredURL, highPortsURL, settingsURL, dockerURL, confirmStopURL] {
            let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0
            #expect(size > 1_000, "\(url.lastPathComponent) looks blank")
        }
```

Keep this loop unchanged — it catches all-blank renders, which the dimension check does not.

### Measured by the advisor on 2026-08-29, before hand-off — read this before Step 1

Two things this plan depends on were checked against the PNGs the suite actually wrote at
`02b3a9c` (`$TMPDIR/squatter-snapshots`, `sips -g pixelWidth -g pixelHeight`), so you are not
inferring them:

| Snapshot | Requested | PNG on disk | Meaning |
|---|---|---|---|
| `list.png` | 360x460 pt | **720x920 px** | pixels = points x 2 (backing scale), as Step 1 assumes |
| `settings.png` | 320x**560** pt | **640x960 px** = 320x**480** pt | `host.bounds` followed the *view's own* fixed frame, not the requested size |

Two consequences:

1. **`host.bounds` really does track content rather than the frame it was handed.** That is
   the mechanism behind the historical 320x3294 render, and it is why the Step 4 canary is
   expected to fail. If it somehow does not, the STOP condition applies.
2. **The settings snapshot is already mismatched today** (480 laid out vs 560 requested), so
   the Step 1 assertion fails on it until Step 2 lands. That is exactly why Step 1 tells you
   not to run the suite yet. Run the suite for the first time at Step 3, with both edits in.

The scale on the machine where this was measured is 2. Still derive it from
`window.backingScaleFactor` — CI runners are commonly 1x.

### Repo rules this plan must honor (restated so you never have to go looking)

- **Do not commit, do not push.** Commits are gated behind owner approval
  (`rules/core-workflow.md`: CHANGELOG gate → release gate → build/verify → commit).
  Leave the work in the working tree and report.
- **Keep Notion current** under `rules/issue-tracker-status.md`; leave tasks `In progress` and report ready for review until owner sign-off.
- **`TRACKER.md`** gets a dated dev-changelog entry. **`CHANGELOG.md` gets nothing** —
  tests are TRACKER-only per the AGENTS.md table ("Refactor, CI, deps, agent docs → No").
- **No new files.** The committed `.pbxproj` enumerates every test file explicitly; a new
  test file silently compiles into nothing without `xcodegen generate`, and CI's
  `project-sync` job diffs the committed project against `project.yml`. This plan edits the
  existing `SnapshotTests.swift` precisely so that trap does not apply. If you find yourself
  creating a file, STOP.

## Commands you will need

Run from the repo root.

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Build | `xcodebuild -project Squatter.xcodeproj -scheme Squatter -configuration Debug build` | `** BUILD SUCCEEDED **` |
| Test | `xcodebuild -project Squatter.xcodeproj -scheme Squatter -destination 'platform=macOS' test` | `** TEST SUCCEEDED **` |

**Baseline: 123 tests in 11 suites pass at `02b3a9c`** (verified 2026-08-29, working tree
clean). This plan adds assertions inside the existing test, not new test cases — the count
stays **123** when you are done.

## Scope

**In scope** (the only files you may modify):
- `SquatterTests/SnapshotTests.swift`
- `TRACKER.md`

**Out of scope**:
- `Squatter/Views/SettingsView.swift` — the 320x480 frame is correct; this plan holds the
  test to it, not the other way around.
- `project.yml` / `Squatter.xcodeproj` / `xcodegen generate` — no new files, so no project
  regeneration. Touching the project here only risks CI's `project-sync` job.
- `CHANGELOG.md` — users notice nothing; tests are TRACKER-only.
- Pixel-content comparison against golden reference images. Deliberately deferred (see
  Maintenance notes); this plan is dimensions + non-blankness only.

## Steps

### Step 1: Teach `snapshot()` to assert dimensions, by name

In `SquatterTests/SnapshotTests.swift`, inside the `snapshot` helper (lines 13-31), add two
assertions and rewrite the doc comment. Target shape — after `host.layoutSubtreeIfNeeded()`
and before the `rep` is created, assert the layout stayed inside the requested frame:

```swift
        host.layoutSubtreeIfNeeded()
        // A view that escapes its frame must fail here, by name. The 2026-08-29 settings
        // regression rendered 320x3294 instead of 320x480 and sailed past the byte check.
        #expect(
            host.bounds.size == size,
            "\(name) escaped its frame: laid out \(host.bounds.width)x\(host.bounds.height) pt, asked for \(size.width)x\(size.height) pt"
        )
```

Then, after `host.cacheDisplay(in: host.bounds, to: rep)`, assert the bitmap's actual pixel
dimensions. **Retina warning**: the PNG's pixel size is the point size multiplied by the
backing scale (2x on Retina Macs, 1x on typical CI runners). Derive the scale from the
window — never hard-code 2:

```swift
        let scale = window.backingScaleFactor
        let expectedWidth = Int((size.width * scale).rounded())
        let expectedHeight = Int((size.height * scale).rounded())
        #expect(
            rep.pixelsWide == expectedWidth && rep.pixelsHigh == expectedHeight,
            "\(name) rendered \(rep.pixelsWide)x\(rep.pixelsHigh) px, expected \(expectedWidth)x\(expectedHeight) px at \(scale)x"
        )
```

Both messages must interpolate `name` — "names which snapshot broke" is a requirement, not
a nicety. Keep the byte-count loop at lines 121-124 exactly as it is.

Finally, replace the doc comment at lines 7-8 with one that tells the truth, e.g.:

```swift
/// Renders the popover in a real (offscreen) window and writes PNGs for eyeballing.
/// Asserts each render fills exactly the frame it was asked for (a view that escapes its
/// frame fails by name) and is not blank; pixel *content* is still eyeball-only.
```

**Verify**: `grep -n 'backingScaleFactor' SquatterTests/SnapshotTests.swift` → exactly one
match; `grep -n 'Not an assertion on pixels' SquatterTests/SnapshotTests.swift` → no matches.
Do not run the test suite yet — the settings snapshot still requests the wrong height and
Step 2 fixes that first.

### Step 2: Render the settings snapshot at its real fixed size

On line 104 (the `settingsURL` call in the "Current state" excerpt), change the requested
height from 560 to 480 so it matches `SettingsView.swift:133`:

```swift
        let settingsURL = try snapshot(SettingsView(settings: settings, model: ignoring).frame(width: 320), name: "settings", size: CGSize(width: 320, height: 480))
```

(Only the `height:` changes. Leave the `.frame(width: 320)` modifier alone — minimal diff.)

**Verify**: `grep -n 'height: 560' SquatterTests/SnapshotTests.swift` → no matches;
`grep -cn 'width: 320, height: 480' SquatterTests/SnapshotTests.swift` → 1.

### Step 3: Run the suite green

**Verify**: `xcodebuild -project Squatter.xcodeproj -scheme Squatter -destination 'platform=macOS' test`
→ `** TEST SUCCEEDED **`, **123 tests, zero failures** (same count as baseline).

If `rendersListEmptyAndErrorStates` fails here, read the failure message — it now names the
snapshot and both sizes. A one-point disagreement (e.g. laid out 320x479.5) means the frame
comparison needs a tolerance; see STOP conditions before inventing one. If the *settings*
snapshot reports a wildly different actual size (hundreds of points off), the settings
layout itself has regressed again — that is a real catch, STOP and report it as a finding.

### Step 4: Prove the assertion fails when it should

A dimension assertion that has only ever passed is indistinguishable from the byte check
this plan replaces. Reproduce the escaped-frame failure mode deliberately:

1. Inside `rendersListEmptyAndErrorStates`, just above the byte-count loop, add a canary
   that demands more height than its window offers — the same shape as the historical bug:

   ```swift
        // TEMPORARY canary for plan 012 step 4 — DELETE before finishing.
        _ = try snapshot(Color.red.frame(width: 360, height: 2000), name: "canary")
   ```

   (`SwiftUI` is already imported at line 3; `Color` resolves.)

2. Run the test command. **Expected: `** TEST FAILED **`**, with a failure message that
   contains the word `canary` and the mismatched sizes — e.g. "canary escaped its frame"
   and/or "canary rendered ... px, expected ... px". Pipe through
   `grep -i canary` if the log is long.

3. **If the suite PASSES with the canary in place, the new assertions are vacuous** —
   `NSHostingView` did not let the content escape `host.bounds` on your macOS version.
   STOP (see STOP conditions) and report the canary's printed/observed `host.bounds` —
   do not invent a different mechanism (e.g. `fittingSize`) without reporting first.

4. Delete the canary lines. Re-run the test command → `** TEST SUCCEEDED **`, 123 tests.

**Verify**: `grep -n 'canary' SquatterTests/SnapshotTests.swift` → no matches, and the last
test run is green. Record in your report: the exact failure message the canary produced.

### Step 5: TRACKER entry

Add a dated (2026-08-29 or the day you execute) dev-changelog entry to `TRACKER.md`: the
snapshot suite now asserts rendered pixel dimensions (scale-derived, not hard-coded 2x)
against the requested size, the settings snapshot is pinned to the fixed 320x480 window, and
the assertion was proven able to fail via a deliberate oversized canary before being
finalized. Do **not** touch `CHANGELOG.md`.

**Verify**: `git status --short` lists exactly two modified files:
`SquatterTests/SnapshotTests.swift` and `TRACKER.md` (plus `plans/README.md` if you maintain
the index yourself).

## Test plan

No new test cases — this plan hardens the existing `rendersListEmptyAndErrorStates` test in
`SquatterTests/SnapshotTests.swift` by adding two assertions per snapshot (twelve snapshots,
all through the one helper). Coverage added:

- A snapshot whose view escapes its requested frame fails, naming the snapshot (proven
  live in Step 4 with the canary, then removed).
- A snapshot whose PNG pixel dimensions disagree with requested-points x backing-scale
  fails, naming the snapshot and both sizes.
- The existing "looks blank" byte check still runs for all twelve snapshots.

Verification: `xcodebuild -project Squatter.xcodeproj -scheme Squatter -destination 'platform=macOS' test`
→ `** TEST SUCCEEDED **`, 123 tests in 11 suites, zero failures.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] Build → `** BUILD SUCCEEDED **`
- [ ] Test → `** TEST SUCCEEDED **`, **123 tests, zero failures** (count unchanged)
- [ ] Step 4 was performed: the canary produced `** TEST FAILED **` with a message naming
      `canary`, and the exact message is quoted in your report
- [ ] `grep -n 'canary' SquatterTests/SnapshotTests.swift` → no matches (canary reverted)
- [ ] `grep -n 'backingScaleFactor' SquatterTests/SnapshotTests.swift` → exactly one match,
      and `grep -n '\* 2\b' SquatterTests/SnapshotTests.swift` → no matches (no hard-coded 2x)
- [ ] `grep -n 'height: 560' SquatterTests/SnapshotTests.swift` → no matches (settings
      renders at the real fixed 320x480)
- [ ] `grep -n 'looks blank' SquatterTests/SnapshotTests.swift` → still one match (byte
      check kept)
- [ ] `grep -n 'Not an assertion on pixels' SquatterTests/SnapshotTests.swift` → no matches
      (doc comment rewritten)
- [ ] `git status --short` shows only `SquatterTests/SnapshotTests.swift` and `TRACKER.md`
      modified (plus `plans/README.md` if you maintain the index)
- [ ] `CHANGELOG.md` untouched; nothing committed, nothing pushed, no Linear issue touched
- [ ] `plans/README.md` status row for 012 updated (unless the dispatcher maintains it)

## STOP conditions

Stop and report back (do not improvise) if:

- The drift check shows `SnapshotTests.swift` or `SettingsView.swift` changed since
  `02b3a9c`, or `SettingsView.swift:133` no longer reads `.frame(width: 320, height: 480)`.
  The expected settings size must come from that line, never from this plan's memory of it.
- **The Step 4 canary does not fail the suite.** That means `host.bounds` does not track
  escaped content on your macOS version and the whole approach is vacuous — the exact trap
  this plan exists to remove. Report the observed `host.bounds` for the canary; the likely
  fallback (asserting `host.fittingSize` against `size`) is a design change the owner
  should sign off on, not something to slip in.
- Step 3 fails with a sub-point mismatch (e.g. 479.5 vs 480) on any snapshot. A tolerance
  is a policy decision — report the exact numbers instead of picking an epsilon.
- Step 3 fails with a large mismatch on the settings snapshot — the layout may have
  regressed again; that is a finding to report, not a number to patch into the test.
- `window.backingScaleFactor` comes back 0 or the pixel math is off by exactly one pixel on
  a fractional-scale display — report the scale and both sizes.
- You find yourself needing to create a new file or touch `project.yml`.

## Maintenance notes

- **What this does and does not catch.** Dimensions catch frame-escape and wrong-window-size
  regressions (the 2026-08-29 class of bug); the byte check catches blank renders. Neither
  catches *wrong content at the right size* — mislabeled buttons, missing rows, bad
  contrast. If that ever bites, the next step is golden-image comparison (perceptual hash or
  per-pixel with tolerance) against checked-in references — deliberately out of scope here
  because reference images are brittle across macOS versions and this repo has no story yet
  for updating them.
- **If the settings window size ever changes** (`SettingsView.swift:133` — and note the
  open product question recorded in `TRACKER.md` about a taller window for the below-fold
  About section), the snapshot's requested size must change in the same commit, and the
  dimension assertion will fail loudly until it does. That is the intent — the test now
  *pins* the shipped size.
- **Reviewer focus**: confirm the executor's report quotes the canary's actual failure
  message (the proof the assertion can fire), and that the scale is derived from
  `window.backingScaleFactor` rather than assumed to be 2.
- **Follow-up deferred**: nothing asserts the PNG *file* on disk re-decodes to the same
  dimensions as the in-memory rep; the file is written from that rep, so this is redundant
  today. Only worth adding if the write path ever gains post-processing.
