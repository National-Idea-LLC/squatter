# Plan 011: Add a "Report a Bug" link to Settings

> **Notion tracking — 2026-09-06:** Current task tracking is in Notion: [Squatter](https://app.notion.com/p/3d3cacb0997081acbbbbfc2bd0f0ddf8), [Tasks](https://app.notion.com/p/3d2cacb09970808d99b7f3c0c0a36f35). Any Linear URLs, IDs, statuses or refusals below are historical references. Resolve migrated IDs via `Linear ID` and verify `Project`; use the Notion task page for all new updates. This supersedes instructions below to create, query, update or close Linear issues. Follow the current repository tracking rule, including its owner-review requirements.

> **Executor instructions**: Follow this plan step by step. Run every verification
> command and confirm the expected result before moving to the next step. If anything
> in the "STOP conditions" section occurs, stop and report — do not improvise. When
> done, update the status row for this plan in `plans/README.md`.
>
> **Drift check (run first)**:
> `git diff --stat 947e97c..HEAD -- Squatter/ViewModels/SettingsModel.swift Squatter/Views/SettingsView.swift`
> If either changed since this plan was written, compare the "Current state" excerpts against
> the live code before proceeding; on a mismatch, STOP.

## Status

- **Priority**: P3
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none (but touches `SettingsView.swift`, like plans 007, 009 and 010 —
  land it last of the batch to avoid re-resolving the same file three times)
- **Category**: dx / direction
- **Planned at**: commit `947e97c`, 2026-08-29

## Why this matters

Squatter ships with no crash reporting, no telemetry and no in-app feedback path — by
design. The consequence is that a user who hits a bug has nowhere to go from inside the app:
Settings offers "Check for Updates" and "View Source", both of which open GitHub, but
neither says "tell us what broke". The issue tracker exists and is public; the app just
never mentions it.

This adds one button that opens a **prefilled** issue form — prefilled with the app version
and the macOS version, which are the two things every report is missing and the two things
the reporter is least likely to know how to find. It is the smallest change in this batch
and the one most likely to pay for itself the first time someone's `lsof` behaves oddly on a
machine nobody here owns.

## Current state

### `SettingsModel` — `Squatter/ViewModels/SettingsModel.swift:6-18, 44-53`

```swift
@MainActor
@Observable
final class SettingsModel {
    static let refreshIntervalChoices: [TimeInterval] = [1, 2, 5]
    static let releasesURL = URL(string: "https://github.com/National-Idea-LLC/squatter/releases")
    static let sourceURL = URL(string: "https://github.com/National-Idea-LLC/squatter")

    /// "0.1.0 (1)" from the bundle, or "—" when running outside a bundle (tests).
    static var bundleVersion: String {
        let info = Bundle.main.infoDictionary ?? [:]
        guard let short = info["CFBundleShortVersionString"] as? String else { return "—" }
        let build = info["CFBundleVersion"] as? String
        return build.map { "\(short) (\($0))" } ?? short
    }
...
    /// No auto-updater: open the GitHub Releases page in the browser.
    func checkForUpdates() {
        guard let url = Self.releasesURL else { return }
        actions.open(url)
    }

    func openSource() {
        guard let url = Self.sourceURL else { return }
        actions.open(url)
    }
```

`init` already takes injectable dependencies, including `appVersion: String = SettingsModel.bundleVersion`
— that is how `SquatterTests/SettingsModelTests.swift:65` pins a version of `"9.9.9 (42)"`
in a test. You will add a `systemVersion` parameter the same way, for the same reason.

`actions` is `any SystemActions` (`Squatter/Services/SystemActions.swift`) — a two-method
protocol (`open`, `copy`) behind which AppKit lives, so tests assert on URLs without opening
a browser. `RecordingActions` in `SquatterTests/TestDoubles.swift` is the double.

### The About section — `Squatter/Views/SettingsView.swift:46-66`

```swift
            Section {
                LabeledContent("Version", value: settings.appVersion)
                LabeledContent {
                    Button("Check for Updates") { settings.checkForUpdates() }
                        .controlSize(.small)
                } label: {
                    Text("Updates")
                }
                LabeledContent {
                    Button("View Source") { settings.openSource() }
                        .controlSize(.small)
                } label: {
                    Text("Open source, MIT")
                }
            } header: {
                Text("About")
            } footer: {
                Text("Squatter never connects to the internet on its own. Checking for updates opens GitHub in your browser.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
```

### The existing test you must not break — `SquatterTests/SettingsModelTests.swift:63-76`

```swift
    @Test func updatesAndSourceOpenGitHubInTheBrowser() {
        let actions = RecordingActions()
        let model = SettingsModel(loginItem: FakeLoginItem(), preferences: Preferences(defaults: freshDefaults()), actions: actions, appVersion: "9.9.9 (42)")
        model.checkForUpdates()
        model.openSource()
        #expect(actions.opened.map(\.absoluteString) == [
            "https://github.com/National-Idea-LLC/squatter/releases",
            "https://github.com/National-Idea-LLC/squatter",
        ])
```

It asserts on an **exact array**, so do not add a `reportBug()` call to it — write a separate
test. Adding a `systemVersion:` parameter with a default keeps this call site compiling.

### Conventions this plan must honor

- `rules/ux-writing.md`: **Title Case** for buttons — "Report a Bug"; **sentence case** for
  the label beside it and the footer. *"Never mention internal infrastructure (CI, hosting,
  repo names) in app UI"* — say "GitHub" in the footer (the existing footer already does,
  and a user needs to know where the button sends them), never the repo path or the org name.
- `rules/ios-swift.md`: strings through `String(localized:)`; no force-unwraps; the model
  holds the logic and the view holds none.
- **Do not commit, do not push, do not touch Linear.**

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Build | `xcodebuild -project Squatter.xcodeproj -scheme Squatter -configuration Debug build` | `** BUILD SUCCEEDED **` |
| Test | `xcodebuild -project Squatter.xcodeproj -scheme Squatter -destination 'platform=macOS' test` | `** TEST SUCCEEDED **` |

**Baseline: 84 tests in 9 suites pass at `947e97c`.** No new files, so no `xcodegen generate`.

## Scope

**In scope**:
- `Squatter/ViewModels/SettingsModel.swift`
- `Squatter/Views/SettingsView.swift`
- `SquatterTests/SettingsModelTests.swift`
- `TRACKER.md`, `CHANGELOG.md`

**Out of scope**:
- Anything that sends a report from inside the app. Squatter makes no network calls
  (`AGENTS.md` golden rule #6); this opens the user's browser and stops there.
- Collecting logs, `lsof` output, a listener list, or any machine identifier into the
  prefilled body. Two version strings and nothing else — a bug report is not a diagnostic
  dump, and the app has no logging to attach anyway.
- A "Give Feedback" link, a Discussions link, or an email address. One button.
- `Squatter/Services/SystemActions.swift` — `open(_:)` already does everything needed.

## Steps

### Step 1: Build the prefilled issue URL in the model

In `Squatter/ViewModels/SettingsModel.swift`:

```swift
    static let issuesURL = URL(string: "https://github.com/National-Idea-LLC/squatter/issues/new")

    /// "Version 15.6 (Build 24G84)" — the second thing every bug report is missing.
    static var systemVersion: String { ProcessInfo.processInfo.operatingSystemVersionString }
```

Add `systemVersion: String = SettingsModel.systemVersion` to `init` (after `appVersion:`),
store it in a `let systemVersion: String`, and add:

```swift
    /// Opens the issue form with the two version strings already filled in. Nothing else is
    /// collected: the body is a template the user edits in their browser before submitting.
    func reportBug() {
        guard let base = Self.issuesURL,
              var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return }
        let body = String(
            localized: """
                What happened:

                What you expected:

                ---
                Squatter \(appVersion)
                macOS \(systemVersion)
                """
        )
        components.queryItems = [URLQueryItem(name: "body", value: body)]
        guard let url = components.url else { return }
        actions.open(url)
    }
```

`URLComponents` does the percent-encoding — do **not** hand-roll it with
`addingPercentEncoding`, and do not interpolate the body into a URL string.

**Verify**: build → `** BUILD SUCCEEDED **`;
`grep -n 'addingPercentEncoding' Squatter/ViewModels/SettingsModel.swift` → no matches.

### Step 2: Add the row to the About section

In `Squatter/Views/SettingsView.swift`, inside the About `Section`, after the "Updates" row
and before "Open source, MIT":

```swift
                LabeledContent {
                    Button("Report a Bug") { settings.reportBug() }
                        .controlSize(.small)
                } label: {
                    Text("Something broken?")
                }
```

and extend the footer to name the new destination:

```swift
                Text("Squatter never connects to the internet on its own. Checking for updates or reporting a bug opens GitHub in your browser.")
```

**Verify**: build → `** BUILD SUCCEEDED **`;
`grep -n 'Report a Bug' Squatter/Views/SettingsView.swift` → exactly one match.

### Step 3: Test it

In `SquatterTests/SettingsModelTests.swift`, add a new test beside
`updatesAndSourceOpenGitHubInTheBrowser` (do not modify that one):

```swift
    @Test func reportBugOpensAPrefilledIssueForm() {
        let actions = RecordingActions()
        let model = SettingsModel(
            loginItem: FakeLoginItem(),
            preferences: Preferences(defaults: freshDefaults()),
            actions: actions,
            appVersion: "9.9.9 (42)",
            systemVersion: "Version 15.6 (Build 24G84)"
        )
        model.reportBug()
        let url = try #require(actions.opened.last)          // mark the test `throws`
        #expect(url.absoluteString.hasPrefix("https://github.com/National-Idea-LLC/squatter/issues/new?body="))
        let body = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "body" }?.value)
        #expect(body.contains("Squatter 9.9.9 (42)"))
        #expect(body.contains("macOS Version 15.6 (Build 24G84)"))
        #expect(body.contains("What happened:"))
        #expect(actions.opened.count == 1)
    }
```

Add one more asserting nothing sensitive leaks into the body:

```swift
    @Test func theBugReportBodyCarriesOnlyVersions() { ... }
```
— assert the body does **not** contain `NSUserName()`, `NSHomeDirectory()`, or the string
`"port"` (case-insensitive). This is the test that stops a future "helpful" change from
attaching the user's listener list to a public issue.

**Verify**: test command → `** TEST SUCCEEDED **`, 2 new tests (86 total from the 84 baseline).

### Step 4: Docs

- `TRACKER.md` — dated entry: the button, what the prefilled body contains, and explicitly
  that nothing else is collected.
- `CHANGELOG.md` `[Unreleased]` → **Added**, e.g. *"Settings has a Report a Bug button that
  opens a new issue with your Squatter and macOS versions already filled in."*

**Verify**: `git status --short` lists only in-scope files.

## Done criteria

ALL must hold:

- [ ] Build → `** BUILD SUCCEEDED **`
- [ ] Test → `** TEST SUCCEEDED **`, 2 new tests, zero failures, and
      `updatesAndSourceOpenGitHubInTheBrowser` passes **unmodified**
- [ ] `grep -n 'Report a Bug' Squatter/Views/SettingsView.swift` → exactly one match
- [ ] `grep -rn 'URLSession\|URLRequest\|dataTask' Squatter/` → no matches (still no network)
- [ ] A test asserts the prefilled body contains no user name, home path, or port data
- [ ] `TRACKER.md` and `CHANGELOG.md` updated
- [ ] Nothing committed, nothing pushed, no Linear issue touched
- [ ] `plans/README.md` status row for 011 updated

## STOP conditions

Stop and report if:

- The About section no longer matches the excerpt (another plan in this batch may have
  landed first) — place the row in whatever the About section now looks like rather than
  pattern-matching blindly.
- GitHub rejects the prefilled URL when you open it by hand. Report the URL you produced;
  do not start trimming the body to make it fit.
- You are tempted to attach the current listener list, `lsof` output, or a log. The issue
  tracker is **public** — a listener list is a description of what the reporter runs on their
  machine and must never be prefilled into a public form.

## Maintenance notes

- The repository URL now appears in three `static let`s in `SettingsModel`. If the repo ever
  moves, all three change together, and `SettingsModelTests` asserts on all three — a rename
  will fail the suite loudly, which is the intent.
- GitHub's `?body=` prefill is a documented, stable behaviour of `issues/new`, but it is
  still someone else's URL contract. If it ever stops working, the fallback is to open
  `issues/new` bare; the button must never break.
- If an issue **template** is ever added to the repo, the `body` parameter will conflict
  with it. At that point drop the query item and pass `?template=bug_report.md` instead.
- A reviewer should check the body text renders as Markdown on GitHub — the `---` line is
  a horizontal rule there, which is what makes the version block read as a footer.
