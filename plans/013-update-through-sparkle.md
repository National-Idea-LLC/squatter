# Plan 013: Squatter updates itself through Sparkle

> **Notion tracking — 2026-09-06:** Current task tracking is in Notion: [Squatter](https://app.notion.com/p/3d3cacb0997081acbbbbfc2bd0f0ddf8), [Tasks](https://app.notion.com/p/3d2cacb09970808d99b7f3c0c0a36f35). Any Linear URLs, IDs, statuses or refusals below are historical references. Resolve migrated IDs via `Linear ID` and verify `Project`; use the Notion task page for all new updates. This supersedes instructions below to create, query, update or close Linear issues. Follow the current repository tracking rule, including its owner-review requirements.

> **Executor instructions**: Follow this plan step by step. Run every verification
> command and confirm the expected result before moving to the next step. If anything
> in the "STOP conditions" section occurs, stop and report — do not improvise. When
> done, update the status row for this plan in `plans/README.md`.
>
> **Drift check (run first)**:
> `git diff --stat ef534b2..HEAD -- project.yml .gitignore Squatter/SquatterApp.swift Squatter/ViewModels/SettingsModel.swift Squatter/Views/SettingsView.swift Squatter/Views/PortListView.swift Squatter/Model/Preferences.swift SquatterTests/SettingsModelTests.swift SquatterTests/TestDoubles.swift SquatterTests/SnapshotTests.swift scripts/release.sh .github/workflows/cask.yml .github/workflows/ci.yml README.md AGENTS.md PROJECT_SPEC.md rules/ios-swift.md rules/secrets-and-config.md`
> If any of these changed since this plan was written, compare the "Current state"
> excerpts against the live code before proceeding; on a mismatch, STOP.
> Expected today: no output (nothing has changed).
>
> **Do the steps in the order written.** Steps 1–3 were reordered on review so that
> the build order and the step order are the same thing.

## Status

- **Priority**: P1 (owner request, 2026-08-30: "add Sparkle for auto updates")
- **Effort**: L
- **Risk**: MED — the first Sparkle release is the one that can go wrong in a way no
  later release can fix: a shipped app whose `SUPublicEDKey` does not match the key the
  appcast is signed with will never accept an update, and a lost private key strands every
  installed copy. Every guard in this plan exists for one of those two failures.
- **Depends on**: none
- **Category**: direction / migration
- **Planned at**: commit `ef534b2`, 2026-08-30 (130 tests in 11 suites green)
- **Reviewed**: 2026-08-30 (`improve review-plan`), against the same commit. The review
  ran Sparkle 2.9.6's real `generate_appcast` against a dummy DMG and re-checked every line
  reference; what it changed is marked *(review)* below. One new fact drives the biggest
  change: **the login Keychain on this Mac already holds a Sparkle EdDSA key** (item
  service `https://sparkle-project.org`, account `ed25519` — Sparkle's default), and it is
  GhostCursor's production key (`~/Developer/ghost-cursor/app/scripts/publish-release.sh`
  runs `generate_appcast` without `--account`). Step 3 is now an owner decision, not a
  `generate_keys` run.

## Why this matters

Squatter is on its fifth release in three days. Today "Check for Updates" opens the GitHub
Releases page in a browser and the user downloads a DMG by hand, or runs `brew upgrade` if
they installed with Homebrew. Nobody does either unprompted, so every fix shipped since a
user's first install is invisible to them. Sparkle is the standard macOS answer: the app
asks once whether it may check, then offers each new version in place, verifies it against
an EdDSA key baked into the app, and swaps the bundle.

This is a deliberate exception to three principles the repo states in writing — "no
third-party packages", "no network calls", "no third-party deps (no Sparkle)" in
`PROJECT_SPEC.md`'s tradeoff table, which already says *"can add Sparkle later"*. The
owner made that call on 2026-08-30. This plan therefore also rewrites every place those
principles are stated, so the docs stop lying the moment the code changes. It does **not**
weaken the parts that still hold: no telemetry (Sparkle's system profiling stays off), the
app itself still makes no request of its own, and the update check is opt-in through
Sparkle's own permission prompt.

Two things this plan deliberately does **not** do, so that nobody re-adds them: it does not
turn on `SUAutomaticallyUpdate` (silent background installs — the user should see what is
being replaced under them), and it does not move signing or the appcast into CI (the
`cask.yml` header explains why the Developer ID certificate stays on the maintainer's Mac;
the Sparkle private key is the same class of secret and stays in the same place).

## Decisions already made — do not re-open these

| Decision | Choice | Why |
|----------|--------|-----|
| Sparkle version | **2.9.6**, pinned with `exactVersion` in `project.yml` | Latest release (2026-08-17). Exact pin so a `brew`-style silent bump cannot change the framework that ships inside a notarized build. Verified: XcodeGen 2.46.0 emits the package reference and the Debug build embeds and signs `Sparkle.framework` with no other changes. |
| Appcast location | `https://github.com/National-Idea-LLC/squatter/releases/latest/download/appcast.xml` | GitHub redirects `releases/latest/download/<asset>` to the newest non-prerelease release's asset. The appcast is one more asset uploaded next to the DMG, so a release needs no GitHub Pages, no commit to `main`, and no second hosting system. The feed lists only the newest version, which is all Sparkle needs. |
| Update archive | The existing signed, notarized, stapled **DMG** — no zip, no deltas (`--maximum-deltas 0`) | Sparkle mounts DMGs natively. One artifact for humans, Homebrew and Sparkle means one checksum and one notarization ticket to get right. The app is ~2 MB; deltas would save nothing. |
| Signing key | EdDSA key from Sparkle's `generate_keys`; private key in the **login Keychain**, public key committed in `project.yml` as `SUPublicEDKey`. **Which Keychain item is the owner's call (step 3)** *(review)*: the login Keychain already holds a key under Sparkle's default account `ed25519`, in production use by GhostCursor. Either Squatter shares it (Sparkle's own advice: *"You only need one signing key, no matter how many apps you embed Sparkle in"*) or gets its own under `--account squatter`. The answer becomes the one constant `SPARKLE_ACCOUNT` in `release.sh`. | Matches `rules/secrets-and-config.md` exactly: "Secrets live in the macOS Keychain only." The public key is not a secret. Sharing means one backup covers both apps; a dedicated account means neither app's key can strand the other's users. Both keys would sit in the same Keychain on the same Mac, so the choice is about independence, not isolation. |
| Release notes | **Embedded** in the appcast item (`generate_appcast --embed-release-notes`) as `<description sparkle:format="markdown">`, cut from `CHANGELOG.md`'s section for the version *(review)* | Verified with 2.9.6 on 2026-08-30: a `Squatter-<version>.md` beside the DMG is picked up (2.9.6 accepts `.html`, `.md`, `.txt`; the 2.6.x tools cached elsewhere on this Mac accept only `.html`/`.txt`, which is one more reason the pin matters) and embedded verbatim. Embedding means the update dialog needs no second download, and the release needs two assets, not three. Sparkle renders markdown natively on macOS 12+; Squatter requires 15. |
| Automatic checks | `SUEnableAutomaticChecks` **unset**, so Sparkle asks the user on the second launch; a Settings toggle mirrors the answer | Opt-in consent for the only network call the app will ever make. Setting the key to `true` would skip the question. |
| What Sparkle may collect | `SUEnableSystemProfiling: false` (explicit, though it is the default) | Golden rule 6, "no telemetry", still holds. |
| Verification before extraction | `SUVerifyUpdateBeforeExtraction: true` | Sparkle checks the EdDSA signature before it mounts the DMG, not after. Costs nothing. |
| Background-app behaviour | Gentle reminders: a scheduled check that finds an update while the popover is closed shows **no window**. A dot appears on the footer gear and the About section's Updates row says "*Version X is available*" with an **Install Update** button. Only a user-initiated check, or the app launching straight into an update, shows Sparkle's own windows. | Squatter is `LSUIElement` with no windows. Sparkle 2.2+ will not steal focus for a scheduled update, which for a dockless app means the alert opens behind everything and is never seen. The delegate hooks below are Sparkle's documented answer. |
| Tests | The updater is constructed but **never started** while running under XCTest; the model layer sees a protocol and tests inject a fake | No network in the suite, no permission prompt during `xcodebuild test`, and the test host shares `sa.ni.squatter` defaults with the real app so a started updater would corrupt the owner's own Sparkle state. |
| Homebrew cask | Gains `auto_updates true` in the tap | Tells `brew upgrade` the app updates itself. **Owner step in the tap repo** — out of this repo's scope, listed under owner follow-ups. |

## Current state

### `project.yml` — the whole project is generated from this

```yaml
# lines 1-11
name: Squatter
options:
  bundleIdPrefix: sa.ni
  ...
# lines 24-53 (Squatter target)
targets:
  Squatter:
    type: application
    platform: macOS
    sources:
      - path: Squatter
        excludes:
          - "Info.plist"
    info:
      path: Squatter/Info.plist
      properties:
        ...
        NSHumanReadableCopyright: "© 2026 National Idea LLC"
    entitlements:
      path: Squatter/Squatter.entitlements
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: sa.ni.squatter
        ...
        ENABLE_HARDENED_RUNTIME: YES
        ENABLE_APP_SANDBOX: NO
```

No `packages:` block exists. `Squatter/Info.plist` is a **generated file** (`xcodegen
generate` writes it from `info.properties`) — never edit it by hand. The generated project
already sets `LD_RUNPATH_SEARCH_PATHS = @executable_path/../Frameworks`
(`project.pbxproj:434`), which is what an embedded framework needs.

### `.gitignore:20-23`

```
# Swift Package Manager
.build/
.swiftpm/
Package.resolved
```

That last line was written when the repo had no packages. With one, Xcode writes the pin
file at `Squatter.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`, and
it **must be committed** so CI and the release build resolve the identical revision.

### `Squatter/SquatterApp.swift` (whole file)

```swift
@main
struct SquatterApp: App {
    @State private var model = PortListModel()
    @State private var settings = SettingsModel()

    init() {
        Preferences.registerToolTipDelay()
    }

    var body: some Scene {
        MenuBarExtra {
            PortListView(model: model, settings: settings)
        } label: { ... }
        .menuBarExtraStyle(.window)
    }
}
```

### `Squatter/ViewModels/SettingsModel.swift`

```swift
// line 9
    static let releasesURL = URL(string: "https://github.com/National-Idea-LLC/squatter/releases")
// lines 45-60
    init(
        loginItem: any LoginItemManaging = SystemLoginItem(),
        preferences: Preferences = Preferences(),
        actions: any SystemActions = AppKitSystemActions(),
        appVersion: String = SettingsModel.bundleVersion,
        systemVersion: String = SettingsModel.systemVersion,
        copyright: String = SettingsModel.bundleCopyright
    ) {
        ...
        self.loginItemStatus = loginItem.status
    }

// lines 62-66
    /// No auto-updater: open the GitHub Releases page in the browser.
    func checkForUpdates() {
        guard let url = Self.releasesURL else { return }
        actions.open(url)
    }
```

The dependency-injection shape to copy is `loginItem: any LoginItemManaging` — a
`@MainActor` protocol in `Squatter/Services/LoginItem.swift` with a real `SystemLoginItem`
and a `FakeLoginItem` in `SquatterTests/TestDoubles.swift:138`. Your `UpdateChecking`
protocol follows it exactly.

### `Squatter/Views/SettingsView.swift:120-154` — the About section

```swift
            Section {
                LabeledContent {
                    Text(settings.appVersion)
                } label: {
                    Text("Version")
                }
                // (comment explaining why Updates and Report a Bug keep buttons)
                LabeledContent {
                    Button("Check for Updates") { settings.checkForUpdates() }
                        .controlSize(.small)
                } label: {
                    Text("Updates")
                }
                LabeledContent {
                    Button("Report a Bug") { settings.reportBug() }
                        .controlSize(.small)
                } label: {
                    Text("Something broken?")
                }
                LinkRow(Text("Open source, MIT"), action: Text("View Source")) { settings.openSource() }
                LinkRow(Text(settings.copyright), action: Text("Visit ni.sa")) { settings.openCompany() }
            } header: {
                Text("About")
            } footer: {
                Text("Squatter never connects to the internet on its own. Checking for updates or reporting a bug opens GitHub in your browser.")
                    .settingsFooter()
            }
```

The first `Section` of the same file (Launch at login) is the pattern for a `Toggle` whose
value lives in `SettingsModel`: `Toggle(isOn: $settings.launchAtLogin) { Text("Launch at login") }`.

### `Squatter/Views/PortListView.swift:207-222` — the footer gear

```swift
            Button {
                isShowingSettings.toggle()
            } label: {
                // Bounce, not rotate: ...
                Image(systemName: "gearshape")
                    .symbolEffect(.bounce.up, options: .nonRepeating, value: isShowingSettings)
            }
            .keyboardShortcut(",")
            .accessibilityLabel(Text("Settings"))
            .help(Text("Settings (⌘,)"))
            .popover(isPresented: $isShowingSettings, arrowEdge: .bottom) {
                SettingsView(settings: settings, model: model)
            }
```

`PortListView` holds `let settings: SettingsModel` (line 6). It is `@Observable`, so a
computed property on it that reads the updater is tracked by SwiftUI.

### `Squatter/Model/Preferences.swift:14-16` — the precedent for a foreign defaults key

```swift
    /// AppKit's own key, so it carries no `squatter.` prefix and must not be renamed.
    /// Milliseconds a control must be hovered before its `.help()` tooltip appears.
    static let initialToolTipDelay = "NSInitialToolTipDelay"
```

### `SquatterTests/SettingsModelTests.swift:58-70` — the test that must change

```swift
    @Test func updatesSourceAndTheCompanyCreditOpenInTheBrowser() {
        let actions = RecordingActions()
        let model = SettingsModel(loginItem: FakeLoginItem(), preferences: Preferences(defaults: freshDefaults()), actions: actions, appVersion: "9.9.9 (42)")
        model.checkForUpdates()
        model.openSource()
        model.openCompany()
        #expect(actions.opened.map(\.absoluteString) == [
            "https://github.com/National-Idea-LLC/squatter/releases",
            "https://github.com/National-Idea-LLC/squatter",
            "https://ni.sa",
        ])
```

It asserts that `checkForUpdates()` opens a browser. After this plan it must not, so this
test is **edited** (step 6), not preserved.

### `scripts/release.sh` — stages, by line

`==> Regenerate project` (32) → `==> Tests` (37, `xcodebuild ... test -quiet` at 38) →
`==> Archive` (40-42) → `==> Export` (44) → `==> Verify signature` (59) → `==> Notarize app`
(68, only with `--notarize`) → `==> DMG` (80) → `==> Notarize` (87-93: submit, `stapler
staple "$DMG"`, `stapler validate`, `spctl`) → final `echo "DMG: ..."` / `echo "sha256: ..."`
(99-100). `VERSION` is read from `MARKETING_VERSION` in `project.yml` (line 25); `$BUILD` is
`build/`, wiped at the start (line 30).

**Stapling modifies the DMG's bytes.** The appcast signature must therefore be computed
*after* the `==> Notarize` stage, never before — a signature over the pre-staple bytes is
worthless.

### `.github/workflows/cask.yml:119-140` — the guard that already exists

The `bump` job downloads the published DMG, mounts it, and refuses to bump the cask unless
`xcrun stapler validate` and `spctl` pass and the bundle version matches the tag. You will
extend it to refuse when the release has no `appcast.xml` asset, so a release that would
silently break updates cannot reach Homebrew either.

### `.github/workflows/ci.yml:26-33`

CI builds with `CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=` (ad-hoc).
**Verified on 2026-08-30 in a scratch copy**: with Sparkle embedded, this exact invocation
resolves the package, ad-hoc signs the framework, and runs all 130 tests green. Library
validation does not reject an ad-hoc framework inside an ad-hoc app. No CI change is needed
beyond the committed `Package.resolved`.

### Conventions this plan must honor

- `rules/ios-swift.md`: SwiftUI first, AppKit only with a comment saying why; strings through
  `String(localized:)`; no force-unwraps outside tests; Swift 6 strict concurrency with no
  `@unchecked Sendable`; views hold no logic.
- `rules/ux-writing.md`: **Title Case** for buttons ("Check for Updates", "Install Update"),
  **sentence case** for labels and footers ("Check for updates automatically"). Never name
  internal infrastructure in the UI — say "GitHub", never the repo path; never say "Sparkle"
  in the UI.
- `rules/secrets-and-config.md`: every persisted key defined once; Sparkle's own keys are
  foreign keys like `NSInitialToolTipDelay` — documented, not renamed, not prefixed.
- Persisted keys, commits, Linear: **do not commit, do not push, do not touch Linear**;
  `TRACKER.md` entry always, `CHANGELOG.md` because this is user-visible.
- Golden rule 9: after the UI change builds, run `scripts/run-debug.sh` so the owner sees it.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Regenerate project | `xcodegen generate` | `Created project at .../Squatter.xcodeproj` |
| Project in sync | `xcodegen generate && git diff --exit-code -- Squatter.xcodeproj` | exit 0 (only `Package.resolved`, which xcodegen does not write, may appear as untracked) |
| Build | `xcodebuild -project Squatter.xcodeproj -scheme Squatter -configuration Debug build` | `** BUILD SUCCEEDED **` |
| Test | `xcodebuild -project Squatter.xcodeproj -scheme Squatter -destination 'platform=macOS' test` | `** TEST SUCCEEDED **`, `Test run with N tests in 11 suites passed` |
| Test, CI-style | same, plus `CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=` | `** TEST SUCCEEDED **` |
| Relaunch | `scripts/run-debug.sh` | `launched .../Squatter.app` |
| Sparkle tools *(review)* | `BUILD_ROOT=$(xcodebuild -project Squatter.xcodeproj -scheme Squatter -showBuildSettings 2>/dev/null \| awk -F' = ' '/^ *BUILD_ROOT = /{print $2; exit}'); SPARKLE="${BUILD_ROOT%/Build/Products}/SourcePackages/artifacts/sparkle/Sparkle"; head -1 "$SPARKLE/CHANGELOG"; ls "$SPARKLE/bin"` (after step 2's build) | `# 2.9.6`, then a listing that includes `generate_appcast`, `generate_keys`, `sign_update`. Do **not** locate the tools with `find` under DerivedData: two other projects on this Mac (`Ice-…`, `GhostCursor-…`) have Sparkle 2.6.x there, and `head -1` would pick one of them. |
| Existing Sparkle key? | `security find-generic-password -s "https://sparkle-project.org" 2>&1 \| grep -E '"acct"\|could not be found'` (prints attributes only, never the secret) | today: `"acct"<blob>="ed25519"` — a key exists (see step 3) |
| Script syntax | `bash -n scripts/release.sh` | exit 0 |
| Workflow syntax | `ruby -ryaml -e 'YAML.load_file(".github/workflows/cask.yml")'` | exit 0 |

**Baseline: 130 tests in 11 suites pass at `ef534b2`.** The first build after step 1 will
download the Sparkle package (~10 MB) — it needs network once.

## Scope

**In scope** (the only files you should modify or create):
- `project.yml`, and `Squatter.xcodeproj/` + `Squatter/Info.plist` via `xcodegen generate` only
- `Squatter.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` (created by Xcode; commit-worthy)
- `.gitignore`
- `Squatter/Services/Updater.swift` (create)
- `Squatter/SquatterApp.swift`
- `Squatter/ViewModels/SettingsModel.swift`
- `Squatter/Views/SettingsView.swift`
- `Squatter/Views/PortListView.swift`
- `Squatter/Model/Preferences.swift` (comment only)
- `SquatterTests/TestDoubles.swift`, `SquatterTests/SettingsModelTests.swift`, `SquatterTests/SnapshotTests.swift`
- `scripts/release.sh`
- `.github/workflows/cask.yml`
- `README.md`, `AGENTS.md`, `PROJECT_SPEC.md`, `rules/ios-swift.md`, `rules/secrets-and-config.md`
- `TRACKER.md`, `CHANGELOG.md`

**Out of scope** (do NOT touch, even though they look related):
- `Squatter/Squatter.entitlements` — a non-sandboxed app needs **no** entitlement for Sparkle.
  If you find yourself adding `com.apple.security.cs.disable-library-validation` or any
  other key, you have misdiagnosed something: STOP.
- `.github/workflows/ci.yml` — verified to work unchanged (see Current state).
- `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` — cutting 0.4.0 is a release gate, the
  owner's call, not part of this plan.
- Anything that uploads to GitHub from `release.sh`. The script stops at local artifacts
  today; keep it that way and print the publish command instead.
- The Homebrew tap repository. `auto_updates true` is an owner step, listed at the end.
- Sparkle's XPC services, `SUEnableInstallerLauncherService` and friends — sandbox-only.
- `SUAutomaticallyUpdate`, `SUScheduledCheckInterval`, `SURequireSignedFeed` — leave at
  Sparkle's defaults; see Maintenance notes.

## Steps

### Step 1: Declare the package and Sparkle's keys in `project.yml`

The public key is not known yet (Sparkle's tools arrive with the package, and the key
choice is step 3), so this step writes a **placeholder** that step 3 replaces. The build in
step 2 does not care what the string is.

Add a top-level `packages:` block **before** `options:`:

```yaml
# Sparkle is the one third-party dependency (owner decision, 2026-08-30 — see
# PROJECT_SPEC.md "Known Tradeoffs"). Pinned exactly: the framework ships inside a
# notarized bundle, so it must not move without a deliberate bump here.
packages:
  Sparkle:
    url: https://github.com/sparkle-project/Sparkle
    exactVersion: 2.9.6
```

In the `Squatter` target, add a `dependencies:` list directly after the `sources:` block
(before `info:`):

```yaml
    dependencies:
      - package: Sparkle
```

In `info.properties`, after `NSHumanReadableCopyright`, add — leaving the placeholder in
place for now (step 3 replaces it):

```yaml
        # Sparkle. The feed is a release asset: GitHub redirects releases/latest/download/<name>
        # to the newest release's copy, so publishing a release is the whole deployment.
        SUFeedURL: https://github.com/National-Idea-LLC/squatter/releases/latest/download/appcast.xml
        # Public half of the EdDSA pair generated with Sparkle's generate_keys. The private
        # half lives in the maintainer's login Keychain and nowhere else. If this and the
        # signing key ever disagree, release.sh refuses to build the appcast.
        SUPublicEDKey: "PLACEHOLDER-REPLACED-IN-STEP-3"
        # Check the signature before touching the archive, not after.
        SUVerifyUpdateBeforeExtraction: true
        # No telemetry: Sparkle's anonymous system profile stays off (this is the default,
        # written down so nobody has to look it up).
        SUEnableSystemProfiling: false
```

Do **not** add `SUEnableAutomaticChecks` — its absence is what makes Sparkle ask the user.

Then in `.gitignore`, delete the `Package.resolved` line (line 22) and replace it with:

```
# Package.resolved is committed: it pins the Sparkle revision every build resolves.
```

**Verify**: `xcodegen generate` → `Created project at ...`; then
`grep -c 'XCRemoteSwiftPackageReference "Sparkle"' Squatter.xcodeproj/project.pbxproj` → `2` or more;
`grep -A1 'SUPublicEDKey' Squatter/Info.plist` → the `<string>` holds `PLACEHOLDER-REPLACED-IN-STEP-3`;
`grep -c 'SUEnableAutomaticChecks' Squatter/Info.plist` → `0`.

### Step 2: Build once — this resolves the package and delivers Sparkle's tools

The first build downloads the Sparkle package (~10 MB; needs network once). If the download
fails with a message that tag or version `2.9.6` cannot be found, STOP — do not pick a
different version.

**Verify**: build → `** BUILD SUCCEEDED **`, with `Resolved source packages: Sparkle ... @ 2.9.6` in the log;
`ls Squatter.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` → exists;
`grep '"version"' Squatter.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` → `"version" : "2.9.6"`;
`git check-ignore -q Squatter.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved; echo $?` → `1` (**no longer ignored**; do not use `git status` for this — it collapses the untracked directory to `?? …/xcshareddata/` and the file name never appears);
`ls "$(xcodebuild -project Squatter.xcodeproj -scheme Squatter -configuration Debug -showBuildSettings 2>/dev/null | awk -F' = ' '/^ *BUILT_PRODUCTS_DIR = /{print $2; exit}')/Squatter.app/Contents/Frameworks"` → `Sparkle.framework`;
then the **Sparkle tools** command from the table → `# 2.9.6` and a `bin` listing with `generate_keys`. Keep that
`$SPARKLE` variable for step 3.

### Step 3: Choose the signing key with the owner, then put its public half in `project.yml`

**3a. Confirm what is in the Keychain** (attributes only — this never prints a secret):

```sh
security find-generic-password -s "https://sparkle-project.org" 2>&1 | grep -E '"acct"|could not be found'
```

Expected today: `"acct"<blob>="ed25519"`. That item is GhostCursor's signing key, created by
`generate_keys` with no `--account` flag. If instead it prints `could not be found`, the
Keychain changed since this plan was written: STOP and report.

**3b. Ask the owner** — this is a gate decision, so use **AskUserQuestion** (golden rule 1),
with these two options and nothing else. If no user is available to answer, STOP; do not
pick one.

> Squatter needs a Sparkle signing key. Your login Keychain already holds one, in use by
> GhostCursor. Which should Squatter use?
> 1. **Share the existing key** *(recommended)* — Sparkle's own guidance is one key per
>    organisation; one backup then covers both apps. `SPARKLE_ACCOUNT="ed25519"`.
> 2. **A dedicated key** under Keychain account `squatter` — the two apps' update paths
>    become independent (rotating or losing one never strands the other's users), at the
>    cost of a second key to back up. `SPARKLE_ACCOUNT="squatter"`.

Owner's answer, if given ahead of time (fill in, then skip the question):
**Option 1 — share the existing key, `SPARKLE_ACCOUNT="ed25519"`** (answered by the
owner on 2026-08-30 through AskUserQuestion; do not ask again).

**3c. Read or create the key** — `$SPARKLE` is from step 2:

- Option 1 (share): `"$SPARKLE/bin/generate_keys" -p` — macOS may ask permission for the
  tool to read the existing item; allow it. Nothing is created.
- Option 2 (dedicated): `"$SPARKLE/bin/generate_keys" --account squatter` — creates the item
  and prints the public key; allow the Keychain write. Then
  `"$SPARKLE/bin/generate_keys" -p --account squatter` prints it alone.

**Verify**: the `-p` command (with `--account squatter` for option 2) → exactly one line of
base64, 44 characters, ending in `=`. Anything else → STOP.

**3d. Put it in the project**: replace `PLACEHOLDER-REPLACED-IN-STEP-3` in `project.yml`
with that line, run `xcodegen generate`, and build again.

**Verify**: `grep -A1 'SUPublicEDKey' Squatter/Info.plist` → the `<string>` equals the `-p`
output; `grep -c PLACEHOLDER project.yml Squatter/Info.plist` → `0` for both; build →
`** BUILD SUCCEEDED **`.

**Never** run `generate_keys -x` to a path inside the repo, and never paste the private key
anywhere. The backup export is an owner step (see Owner follow-ups). Remember the chosen
account name: step 8 writes it into `release.sh` as `SPARKLE_ACCOUNT`.

### Step 4: The updater service — `Squatter/Services/Updater.swift` (create)

Model it on `LoginItem.swift`: a `@MainActor` protocol, one real implementation. This
exact shape compiled under Swift 6 strict concurrency on 2026-08-30; the
`@preconcurrency` on the delegate conformance is load-bearing (Sparkle's delegate
protocol is not main-actor-annotated, `SPUUpdater` is).

```swift
import AppKit
import Observation
import Sparkle

/// What the settings model needs from an updater, so it can be tested with a fake.
@MainActor
protocol UpdateChecking: AnyObject {
    /// False while a check is already running or the updater has not started.
    var canCheckForUpdates: Bool { get }
    /// Sparkle persists this itself (`SUEnableAutomaticChecks` in the app's defaults).
    var automaticallyChecksForUpdates: Bool { get set }
    /// The version a background check found and we chose not to interrupt the user with.
    var pendingUpdateVersion: String? { get }
    /// User-initiated: shows Sparkle's own windows, including for an already-found update.
    func checkForUpdates()
}

/// Sparkle behind `UpdateChecking`. Squatter has no windows and no Dock icon, so a scheduled
/// check that finds an update must not open an alert nobody will see (Sparkle 2.2+ refuses
/// to steal focus for scheduled updates, which for a dockless app means "behind everything").
/// Instead the found version is recorded and the UI shows it; the user's click on
/// "Install Update" is a normal `checkForUpdates()`, which Sparkle presents in focus.
@MainActor
@Observable
final class SparkleUpdater: NSObject, UpdateChecking {
    private(set) var canCheckForUpdates = false
    private(set) var pendingUpdateVersion: String?

    @ObservationIgnored private var controller: SPUStandardUpdaterController!
    @ObservationIgnored private var observation: NSKeyValueObservation?

    /// - Parameter startingUpdater: pass `false` under tests — a started updater schedules
    ///   checks and can show the permission prompt, against the test host's shared defaults.
    init(startingUpdater: Bool) {
        super.init()
        controller = SPUStandardUpdaterController(
            startingUpdater: startingUpdater,
            updaterDelegate: nil,
            userDriverDelegate: self
        )
        // KVO rather than Combine: the model is @Observable and needs a plain property to publish.
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            MainActor.assumeIsolated { self?.canCheckForUpdates = updater.canCheckForUpdates }
        }
    }

    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    func checkForUpdates() { controller.updater.checkForUpdates() }

    // MARK: Decisions, kept free of Sparkle types so they can be tested

    /// Sparkle may show a scheduled update itself only when it can do so in focus — in
    /// practice, right at launch. Otherwise we hold it and surface it in the UI.
    static func shouldPresentScheduledUpdate(inImmediateFocus immediateFocus: Bool) -> Bool {
        immediateFocus
    }

    /// Called for every update Sparkle is about to show or that we declined to show.
    func noteUpdate(version: String, presentedBySparkle: Bool) {
        pendingUpdateVersion = presentedBySparkle ? nil : version
    }

    func noteUpdateSessionFinished() {
        pendingUpdateVersion = nil
    }

    /// The user has now seen the update — Sparkle's alert came to the front, or they chose
    /// to install, skip or dismiss it. The dot has done its job. (review: Sparkle's header
    /// names this callback as the place to dismiss custom indicators, and it is the one
    /// that fires when a held update is brought into focus by "Install Update".)
    func noteUserAttention() {
        pendingUpdateVersion = nil
    }
}

// `@preconcurrency`: Sparkle declares this protocol without an actor, and the class is
// main-actor bound. Sparkle calls its user-driver delegate on the main thread.
extension SparkleUpdater: @preconcurrency SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        Self.shouldPresentScheduledUpdate(inImmediateFocus: immediateFocus)
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        noteUpdate(version: update.displayVersionString, presentedBySparkle: handleShowingUpdate)
    }

    func standardUserDriverWillFinishUpdateSession() {
        noteUpdateSessionFinished()
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        noteUserAttention()
    }
}
```

Everything above except the two `UserAttention` members is the exact shape that compiled
on 2026-08-30. The attention callback was added on review from Sparkle's header
(`standardUserDriverDidReceiveUserAttentionForUpdate:`); if the compiler rejects only that
method's name, `grep -n DidReceiveUserAttention "$SPARKLE/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework/Versions/B/Headers/SPUStandardUserDriverDelegate.h"`
shows the selector, and the Swift name is the usual import of it — fix the spelling, nothing else.

**The project file lists every source explicitly** (XcodeGen output; there is no
file-system-synchronized group), so a new file is not compiled until the project is
regenerated. Run `xcodegen generate` now, and again whenever you create a file.

**Verify**: `xcodegen generate` → `Created project at ...`;
`grep -c 'Updater.swift' Squatter.xcodeproj/project.pbxproj` → `2` or more;
build → `** BUILD SUCCEEDED **`, zero warnings mentioning `Updater.swift`
(`SWIFT_TREAT_WARNINGS_AS_ERRORS` is on, so a warning fails the build anyway).

### Step 5: Wire it through `SettingsModel` and `SquatterApp`

`Squatter/ViewModels/SettingsModel.swift`:

1. Delete `static let releasesURL` (line 9). Nothing else uses it.
2. Add a **required** init parameter `updater: any UpdateChecking` — place it right after
   `loginItem:`, with no default. (A default would have to construct a Sparkle object inside
   every test and preview; explicit injection is the point.) Store it as
   `@ObservationIgnored private let updater: any UpdateChecking`.
3. Replace `checkForUpdates()`:

```swift
    /// User-initiated. Sparkle shows its own progress and result windows; if a background
    /// check already found a version, this is also how the user gets to install it.
    func checkForUpdates() {
        updater.checkForUpdates()
    }

    var canCheckForUpdates: Bool { updater.canCheckForUpdates }

    /// Newest version a background check found, or nil. Drives the dot on the footer gear
    /// and the Updates row in About.
    var pendingUpdateVersion: String? { updater.pendingUpdateVersion }

    /// Bindable. Sparkle owns the persistence — it asks the user on the second launch and
    /// stores the answer in the app's defaults under its own key.
    var automaticUpdateChecks: Bool {
        get { updater.automaticallyChecksForUpdates }
        set { updater.automaticallyChecksForUpdates = newValue }
    }
```

`Squatter/SquatterApp.swift`:

```swift
@main
struct SquatterApp: App {
    @State private var model = PortListModel()
    @State private var settings: SettingsModel

    init() {
        Preferences.registerToolTipDelay()
        // Never start the updater under XCTest: the test host shares the app's defaults,
        // so a started updater would schedule real checks and could show the permission
        // prompt in the middle of a test run.
        let isTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        _settings = State(initialValue: SettingsModel(updater: SparkleUpdater(startingUpdater: !isTesting)))
    }
    // body unchanged
}
```

`Squatter/Model/Preferences.swift` — in `DefaultsKeys`, after `initialToolTipDelay`, add
a comment only (no constants: the app never reads these keys itself):

```swift
    // Sparkle stores its own state in this app's defaults under its own, unprefixed keys —
    // `SUEnableAutomaticChecks`, `SUScheduledCheckInterval`, `SULastCheckTime`,
    // `SUHasLaunchedBefore`, `SUSkippedVersion`. Read and written only through
    // `SparkleUpdater`; never renamed, never mirrored here.
```

Fix the two previews so they compile: `SettingsView.swift:249` and `PortListView.swift:349`
pass `updater: SparkleUpdater(startingUpdater: false)`.

**Verify**: build → `** BUILD SUCCEEDED **`;
`grep -rn 'releasesURL' Squatter/` → no output, exit 1 (the `-r` matters: without it grep
reports "Is a directory" and exits 2);
`grep -c 'XCTestConfigurationFilePath' Squatter/SquatterApp.swift` → `1`.
(The test target will not compile yet — that is step 6.)

### Step 6: Test doubles and model tests

`SquatterTests/TestDoubles.swift`, next to `FakeLoginItem`:

```swift
/// Scripted updater: records checks, holds the automatic-checks flag in memory, and lets a
/// test plant a "found" version the way a background check would.
@MainActor
final class FakeUpdater: UpdateChecking {
    var canCheckForUpdates = true
    var automaticallyChecksForUpdates = false
    var pendingUpdateVersion: String?
    private(set) var checkCalls = 0

    init(pendingUpdateVersion: String? = nil) { self.pendingUpdateVersion = pendingUpdateVersion }

    func checkForUpdates() { checkCalls += 1 }
}
```

Every `SettingsModel(` call in the tests needs `updater:`. There are **12** in
`SnapshotTests.swift` (11 identical ones between lines 71 and 132, plus the settings one
at line 117) and **6** in `SettingsModelTests.swift` (lines 8, 51, 60, 81, 87, 107). The
`sed` below rewrites exactly the identical ones — the 11 in `SnapshotTests.swift` **and
line 81** of `SettingsModelTests.swift`, which has the same text; that is intended:

```sh
/usr/bin/sed -i '' 's/SettingsModel(loginItem: FakeLoginItem(), preferences: Preferences(defaults: freshDefaults()))/SettingsModel(loginItem: FakeLoginItem(), updater: FakeUpdater(), preferences: Preferences(defaults: freshDefaults()))/g' SquatterTests/SnapshotTests.swift SquatterTests/SettingsModelTests.swift
```

**Verify**: `grep -c 'updater: FakeUpdater()' SquatterTests/SnapshotTests.swift SquatterTests/SettingsModelTests.swift` → `11` and `1`.

Then hand-edit the six that remain, adding `updater: FakeUpdater(),` right after the
`loginItem:` argument: `SettingsModelTests.swift` lines 8 (`make()`), 51 (the one using a
`defaults` variable), 60, 87 and 107 (these pass extra arguments such as `actions:`, which
is why the `sed` pattern does not match them), and `SnapshotTests.swift:117`. For line 117
use `updater: FakeUpdater(pendingUpdateVersion: "9.9.9")` so `settings.png` renders the
"available" state of the Updates row — that is the state a reviewer most needs to see.

**Verify**: `grep -c 'SettingsModel(' SquatterTests/SnapshotTests.swift SquatterTests/SettingsModelTests.swift` → `12` and `6`;
`grep -c 'updater: FakeUpdater' SquatterTests/SnapshotTests.swift SquatterTests/SettingsModelTests.swift` → `12` and `6`.

In `SettingsModelTests.swift`:

- Rename `updatesSourceAndTheCompanyCreditOpenInTheBrowser` to
  `sourceAndTheCompanyCreditOpenInTheBrowser`, delete its `model.checkForUpdates()` line and
  the `.../releases` element of the expected array. Keep everything else.
- Add:

```swift
    @Test func checkingForUpdatesAsksTheUpdaterNotTheBrowser() {
        let actions = RecordingActions()
        let updater = FakeUpdater()
        let model = SettingsModel(loginItem: FakeLoginItem(), updater: updater, preferences: Preferences(defaults: freshDefaults()), actions: actions)
        model.checkForUpdates()
        #expect(updater.checkCalls == 1)
        #expect(actions.opened.isEmpty)
    }

    @Test func automaticChecksRoundTripThroughTheUpdater() {
        let updater = FakeUpdater()
        let model = SettingsModel(loginItem: FakeLoginItem(), updater: updater, preferences: Preferences(defaults: freshDefaults()))
        #expect(!model.automaticUpdateChecks)
        model.automaticUpdateChecks = true
        #expect(updater.automaticallyChecksForUpdates)
        #expect(model.automaticUpdateChecks)
    }

    @Test func aVersionFoundInTheBackgroundIsSurfaced() {
        let updater = FakeUpdater(pendingUpdateVersion: "9.9.9")
        let model = SettingsModel(loginItem: FakeLoginItem(), updater: updater, preferences: Preferences(defaults: freshDefaults()))
        #expect(model.pendingUpdateVersion == "9.9.9")
        #expect(model.canCheckForUpdates)
    }

    /// The decisions the Sparkle delegate makes, tested without Sparkle objects.
    @Test func scheduledUpdatesAreOnlyShownInImmediateFocus() {
        #expect(SparkleUpdater.shouldPresentScheduledUpdate(inImmediateFocus: true))
        #expect(!SparkleUpdater.shouldPresentScheduledUpdate(inImmediateFocus: false))
    }

    @Test func aHeldUpdateIsRememberedUntilTheSessionEnds() {
        let updater = SparkleUpdater(startingUpdater: false)
        updater.noteUpdate(version: "9.9.9", presentedBySparkle: false)
        #expect(updater.pendingUpdateVersion == "9.9.9")
        updater.noteUpdate(version: "9.9.9", presentedBySparkle: true)
        #expect(updater.pendingUpdateVersion == nil)
        updater.noteUpdate(version: "9.9.9", presentedBySparkle: false)
        updater.noteUserAttention()
        #expect(updater.pendingUpdateVersion == nil)
        updater.noteUpdate(version: "9.9.9", presentedBySparkle: false)
        updater.noteUpdateSessionFinished()
        #expect(updater.pendingUpdateVersion == nil)
    }
```

**Verify**: test → `** TEST SUCCEEDED **`, `Test run with 135 tests in 11 suites passed`
(130 baseline + 5). Then the CI-style variant → `** TEST SUCCEEDED **` too.

### Step 7: The Settings UI

In `Squatter/Views/SettingsView.swift`, replace the Updates `LabeledContent` (lines 131-137)
with:

```swift
                LabeledContent {
                    if settings.pendingUpdateVersion != nil {
                        Button("Install Update") { settings.checkForUpdates() }
                            .controlSize(.small)
                    } else {
                        Button("Check for Updates") { settings.checkForUpdates() }
                            .controlSize(.small)
                            .disabled(!settings.canCheckForUpdates)
                    }
                } label: {
                    if let version = settings.pendingUpdateVersion {
                        Text("Version \(version) is available")
                    } else {
                        Text("Updates")
                    }
                }
                Toggle(isOn: $settings.automaticUpdateChecks) {
                    Text("Check for updates automatically")
                }
```

Replace the About footer text (line 152) with:

```swift
                Text("Checking for updates is the only time Squatter goes online, and it asks before it starts doing that on its own. Reporting a bug opens GitHub in your browser.")
```

In `Squatter/Views/PortListView.swift`, on the gear `Image` (line 214), add a badge:

```swift
                Image(systemName: "gearshape")
                    .symbolEffect(.bounce.up, options: .nonRepeating, value: isShowingSettings)
                    // A found update waits here instead of in an alert the user would never
                    // see: Squatter has no windows for one to land in front of.
                    .overlay(alignment: .topTrailing) {
                        if settings.pendingUpdateVersion != nil {
                            Circle()
                                .fill(.tint)
                                .frame(width: 6, height: 6)
                                .offset(x: 3, y: -3)
                        }
                    }
```

and make the accessibility label carry it (line 218):

```swift
            .accessibilityLabel(settings.pendingUpdateVersion == nil ? Text("Settings") : Text("Settings, update available"))
```

(Two `Text` literals, not one `Text(String)`: a string literal passed to `Text` is a
localized key, a `String` value is not — `rules/ios-swift.md` wants the former.)

**Verify**: build → `** BUILD SUCCEEDED **`; test → `** TEST SUCCEEDED **`, still 135;
`grep -c 'Install Update' Squatter/Views/SettingsView.swift` → `1`;
`grep -rn '"[^"]*[Ss]parkle[^"]*"' Squatter/Views/` → no matches (the word may appear in a
comment, never inside a string literal — nothing in the UI names the framework);
`grep -n 'never connects to the internet' Squatter/Views/SettingsView.swift` → no matches;
open `$TMPDIR/squatter-snapshots/settings.png` and confirm the row reads "Version 9.9.9 is available" with an **Install Update** button and the toggle beneath it.

Then **`scripts/run-debug.sh`** (golden rule 9) and check, in the running app:

1. The gear has no dot (nothing pending); Settings › About shows Updates / Check for
   Updates enabled, and the new toggle.
2. Flip the toggle on. It stays on. Then
   `defaults read sa.ni.squatter SUEnableAutomaticChecks` → `1`; flip it off → `0`.
   (Why check with `defaults`: the toggle is bound to a pass-through into Sparkle, not to
   observable state, so nothing re-renders when it is set — the control keeps its own
   visual state and every later render re-reads Sparkle's value. That is expected, not a
   defect. Because you set the key yourself, Sparkle will **not** show its
   "Check for updates automatically?" prompt on the next launch — if you want to see the
   prompt, `defaults delete sa.ni.squatter SUEnableAutomaticChecks` and relaunch.)
3. **Expect and accept**: clicking Check for Updates reports an error, because no release
   carries an `appcast.xml` yet — `releases/latest/download/appcast.xml` is a 404 until
   0.4.0 ships. Report that you saw the error dialog rather than a crash.

### Step 8: `scripts/release.sh` — build the signed appcast next to the DMG

Four edits.

**8a. Deterministic package path.** Add `-derivedDataPath "$BUILD/DerivedData"` to both
xcodebuild calls at lines 38 and 41-42, so the Sparkle tools land at a path the script
controls (`build/` is wiped at the top, so every release resolves the pinned package fresh):

```sh
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -destination 'platform=macOS' \
  -derivedDataPath "$BUILD/DerivedData" test -quiet
...
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
  -derivedDataPath "$BUILD/DerivedData" -archivePath "$ARCHIVE" archive -quiet
```

Add, after the `EXPORT=` line near the top:

```sh
SPARKLE_BIN="$BUILD/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin"
# Keychain account holding the Sparkle EdDSA key (step 3 of plan 013). "ed25519" is
# Sparkle's default account, shared with GhostCursor; "squatter" if the owner chose a
# dedicated key. Both tools below must use the same account or the appcast is unsigned.
SPARKLE_ACCOUNT="ed25519"
```

Write the account the owner chose in step 3 — `ed25519` for option 1, `squatter` for
option 2.

**8b. Refuse a build whose public key is not the signing key.** In `==> Verify signature`,
after the sandbox check (line 65), add:

```sh
# The app must carry the public half of the key the appcast will be signed with. If they
# differ, every copy of this build would reject every future update — and generate_appcast
# only *warns* about the mismatch, then writes an unsigned item and exits 0. Fail here.
[[ -x "$SPARKLE_BIN/generate_keys" ]] || { echo "Sparkle tools not found under $SPARKLE_BIN"; exit 1; }
KEYCHAIN_PUBLIC_KEY=$("$SPARKLE_BIN/generate_keys" -p --account "$SPARKLE_ACCOUNT")
BUNDLE_PUBLIC_KEY=$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$EXPORT/$APP/Contents/Info.plist")
if [[ "$KEYCHAIN_PUBLIC_KEY" != "$BUNDLE_PUBLIC_KEY" ]]; then
  echo "SUPublicEDKey in the app does not match the Sparkle key in the login Keychain."
  echo "Run generate_keys, put its public key in project.yml, and rebuild."; exit 1
fi
```

**8c. Generate the appcast — after the DMG is stapled.** Insert a new stage after the
`==> Notarize` block's `fi` (after line 96) and before the final `echo`s:

```sh
echo "==> Appcast"
# Signed over the *final* DMG bytes: stapling changed them, so this cannot run earlier.
# (Without --notarize this still runs, over the unstapled DMG — useful for checking the
# pipeline, but only a --notarize run produces an appcast that may be published.)
# generate_appcast wants a directory; give it one holding exactly this release, plus a
# Squatter-<version>.md beside the DMG, which it embeds in the item as markdown release
# notes. Notes come from CHANGELOG.md, so a version that has not been cut there cannot
# be released.
APPCAST_DIR="$BUILD/appcast"
mkdir -p "$APPCAST_DIR"
cp "$DMG" "$APPCAST_DIR/"
NOTES="$APPCAST_DIR/Squatter-$VERSION.md"
awk -v v="## [$VERSION]" 'index($0, v) == 1 {p=1; next} /^## \[/ {p=0} p' CHANGELOG.md > "$NOTES"
[[ -s "$NOTES" ]] || { echo "CHANGELOG.md has no '## [$VERSION]' section — cut the release there first"; exit 1; }
RELEASE_URL="https://github.com/National-Idea-LLC/squatter/releases/download/v$VERSION/"
"$SPARKLE_BIN/generate_appcast" \
  --account "$SPARKLE_ACCOUNT" \
  --download-url-prefix "$RELEASE_URL" \
  --embed-release-notes \
  --link "https://github.com/National-Idea-LLC/squatter" \
  --full-release-notes-url "https://github.com/National-Idea-LLC/squatter/blob/main/CHANGELOG.md" \
  --maximum-deltas 0 \
  -o "$BUILD/appcast.xml" \
  "$APPCAST_DIR"
# On a key mismatch generate_appcast prints a warning, writes the item with NO
# sparkle:edSignature attribute, and exits 0 (verified with 2.9.6). Refuse that.
grep -q 'sparkle:edSignature="' "$BUILD/appcast.xml" || { echo "appcast.xml has no EdDSA signature — refusing"; exit 1; }
grep -q "$RELEASE_URL""Squatter-$VERSION.dmg" "$BUILD/appcast.xml" || { echo "appcast.xml does not point at Squatter-$VERSION.dmg under v$VERSION"; exit 1; }
grep -q "<sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>" "$BUILD/appcast.xml" || { echo "appcast.xml is not for $VERSION"; exit 1; }
grep -q 'sparkle:format="markdown"' "$BUILD/appcast.xml" || { echo "appcast.xml has no embedded release notes"; exit 1; }
```

What a correct run writes (from the review's dummy run — the item shape you should see):

```xml
<item>
    <title>0.4.0</title>
    <link>https://github.com/National-Idea-LLC/squatter</link>
    <sparkle:fullReleaseNotesLink>https://github.com/National-Idea-LLC/squatter/blob/main/CHANGELOG.md</sparkle:fullReleaseNotesLink>
    <sparkle:version>5</sparkle:version>
    <sparkle:shortVersionString>0.4.0</sparkle:shortVersionString>
    <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
    <description sparkle:format="markdown"><![CDATA[ ...the CHANGELOG section... ]]></description>
    <enclosure url="https://github.com/National-Idea-LLC/squatter/releases/download/v0.4.0/Squatter-0.4.0.dmg" length="…" type="application/octet-stream" sparkle:edSignature="…"/>
</item>
```

`generate_appcast` also refuses an app that fails `codesign` verification and, when the
account holds **no** key at all, exits non-zero with "lack of private EdDSA key" — both
are the loud failures you want; neither needs handling.

**8d. Say how to publish.** Replace the final two `echo`s (lines 99-100) with:

```sh
echo "DMG:     $DMG"
echo "sha256:  $(shasum -a 256 "$DMG" | cut -d' ' -f1)"
echo "appcast: $BUILD/appcast.xml"
echo "notes:   $NOTES"
echo
echo "Publish the DMG and the appcast as assets of the same release — Sparkle reads the"
echo "appcast from the 'latest' release, and the release notes are embedded in it:"
echo "  gh release create v$VERSION \"$DMG\" \"$BUILD/appcast.xml\" --title \"Squatter $VERSION\" --notes-file \"$NOTES\""
```

(Line 98's bare `echo` stays; the replacement starts at the `DMG:` line so there is one
blank line, not two.)

Replace the usage comment at the top of the script (lines 2-8, everything before
`set -euo pipefail`) with:

```sh
# Builds a signed, optionally notarized Squatter release DMG, plus the signed Sparkle
# appcast that tells installed copies about it.
#
#   scripts/release.sh                 # archive, sign, DMG, appcast (no notarization)
#   scripts/release.sh --notarize      # also notarize + staple; only this output is publishable
#
# Before a release: bump BOTH MARKETING_VERSION and CURRENT_PROJECT_VERSION in project.yml
# (Sparkle compares the build number — a reused one is invisible to installed copies) and
# cut the version's section in CHANGELOG.md (the appcast embeds it as release notes).
#
# Notarization needs a keychain profile created once with:
#   xcrun notarytool store-credentials squatter --apple-id <id> --team-id M8A3G95883 --password <app-specific-password>
# The appcast needs the Sparkle EdDSA key in the login Keychain under $SPARKLE_ACCOUNT
# (Sparkle's generate_keys); the app's SUPublicEDKey must be that key's public half.
```

**Verify**: `bash -n scripts/release.sh` → exit 0;
`grep -c 'derivedDataPath' scripts/release.sh` → `2`;
`grep -n '==> Appcast' scripts/release.sh` → one match, and its line number is **greater**
than the line of `xcrun stapler staple "$DMG"` (`grep -n 'stapler staple "\$DMG"' scripts/release.sh`);
`grep -c 'sparkle:edSignature' scripts/release.sh` → `1`;
`grep -c -- '--account "\$SPARKLE_ACCOUNT"' scripts/release.sh` → `2` (generate_keys and generate_appcast);
`grep -c 'embed-release-notes' scripts/release.sh` → `1`.

You cannot run the whole script without the Developer ID identity and notarization
profile; do not try. The `awk` extraction you **can** test:
`awk -v v="## [0.3.0]" 'index($0, v) == 1 {p=1; next} /^## \[/ {p=0} p' CHANGELOG.md | head -4`
→ an empty line, the 0.3.0 summary sentence ("A new app icon drawn for the way…"), an
empty line, then `### Added`. (The leading blank line is harmless in markdown; `[[ -s ]]`
only cares that the section exists.)

### Step 9: `cask.yml` — refuse to bump the cask for a release with no appcast

In `.github/workflows/cask.yml`, in the `Download the published DMG` step, replace the
download command (line 116) with:

```sh
          gh release download "$TAG" --repo "$GITHUB_REPOSITORY" --pattern "$DMG" --pattern "appcast.xml" --dir dist
          ls -l dist
```

Then extend the `Refuse to ship…` step (lines 119-140). Its `env:` block (lines 120-122)
exports only `DMG` and `VERSION`; the lines below use `$TAG`, and under `set -u` an
unexported `TAG` aborts the step. Add to that `env:` block:

```yaml
          TAG: ${{ steps.rel.outputs.tag }}
```

and add to the end of the step's `run:` (after the `echo "Verified: ..."` line 140):

```sh
          # Sparkle reads the appcast from the latest release. A release without one, or with
          # an unsigned or mis-pointed one, would leave every installed copy unable to update
          # — the cask must not advertise that build either.
          [ -s dist/appcast.xml ] || { echo "Release $TAG has no appcast.xml asset"; exit 1; }
          grep -q 'sparkle:edSignature="' dist/appcast.xml || { echo "appcast.xml is unsigned"; exit 1; }
          grep -q "releases/download/$TAG/$DMG" dist/appcast.xml || { echo "appcast.xml does not point at $DMG under $TAG"; exit 1; }
          grep -q "<sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>" dist/appcast.xml || { echo "appcast.xml version is not $VERSION"; exit 1; }
          echo "Verified: appcast present, signed, points at $DMG"
```

Update the step's `name:` to `Refuse to ship an unnotarized, unstapled, mislabelled, or update-less build`.

**Verify**: `ruby -ryaml -e 'YAML.load_file(".github/workflows/cask.yml")'` → exit 0;
`grep -c 'dist/appcast.xml' .github/workflows/cask.yml` → `4` (the `[ -s ]` test and three greps);
`grep -c 'TAG: \${{ steps.rel.outputs.tag }}' .github/workflows/cask.yml` → `2` (download step, and the guard step you just edited).

### Step 10: Tell the truth in the docs

Each line below is currently false or about to be; change them, and nothing else in
those files.

- `README.md:32-33`: replace the two bullets with
  - `- **No telemetry.** The only time Squatter goes online is to check for an update, and it asks you before it starts doing that on its own.`
  - `- **One dependency.** [Sparkle](https://sparkle-project.org) for updates; everything else is Swift 6 / SwiftUI.`
- `AGENTS.md:5`: `zero third-party dependencies` → `one third-party dependency (Sparkle, for updates — pinned in \`project.yml\`)`.
- `AGENTS.md:19` (golden rule 6): `No third-party packages, no App Sandbox, no privilege escalation, no telemetry or network calls.` → `No third-party packages beyond Sparkle, no App Sandbox, no privilege escalation, no telemetry, and no network calls other than Sparkle's update check.`
- `AGENTS.md:73`: `**Secrets:** none expected.` → `**Secrets:** one — the Sparkle EdDSA signing key, which lives in the maintainer's login Keychain (\`generate_keys\`) and nowhere else. Any other secret: Keychain only — never UserDefaults, plists, or committed files.`
- `AGENTS.md:37` (the `scripts/release.sh [--notarize]` command line): replace the whole bullet with
  `- \`scripts/release.sh [--notarize]\` — test, archive, export Developer ID, verify, build and sign the DMG, then write a signed \`appcast.xml\` beside it; \`--notarize\` also submits and staples (needs the \`squatter\` keychain profile and the Sparkle EdDSA key in the login Keychain). Bump **both** \`MARKETING_VERSION\` and \`CURRENT_PROJECT_VERSION\` first — Sparkle compares the build number, so a reused one is invisible to installed copies. Upload the DMG and \`appcast.xml\` to the same GitHub Release.`
- `PROJECT_SPEC.md:71`: `- [ ] **Sparkle-free updates**: ...` → `- [x] **Updates via Sparkle** (added 2026-08-30, superseding "Sparkle-free updates"): the app checks a signed appcast published as a GitHub Release asset, after asking the user once.`
- `PROJECT_SPEC.md:23`: `Single Xcode target, no third-party dependencies` → `Single Xcode target, one third-party dependency (Sparkle)`.
- `PROJECT_SPEC.md:258`: `No telemetry, no analytics, no network calls at all` → `No telemetry, no analytics; the only network call is Sparkle's update check (opt-in).`
- `PROJECT_SPEC.md:264`: `- [x] No network access; no data leaves the machine.` → `- [x] No data leaves the machine. The only outbound request is Sparkle's update check (opt-in); system profiling is off.`
- `PROJECT_SPEC.md:284`: `| No third-party deps (no Sparkle) | Manual updates | Minimalism; can add Sparkle later |` → `| Sparkle for updates (decided 2026-08-30) | One third-party framework, one signing key to protect | Users never saw fixes otherwise; the feed is a release asset, so releasing is still one step |`.
- `rules/ios-swift.md:27`: `No Keychain, network, or file storage expected.` → `No file storage, and no network beyond Sparkle's update check. Adding either is an architecture change — ask first.`
- `rules/secrets-and-config.md:12`: `Squatter has no accounts, no API keys, and makes no network calls. Keep it that way; if a secret is ever unavoidable:` → `Squatter has no accounts and no API keys; its only network call is Sparkle's update check. Its one secret is the Sparkle EdDSA private key, kept in the maintainer's login Keychain by \`generate_keys\` — never exported into the repo. For anything else:`.
- `TRACKER.md`: add an M3 task line `- [x] Updates via Sparkle (plan 013)` and a dated
  changelog entry: what was added, the decisions in the table above in one paragraph
  (including which Keychain account the owner chose and why), and — explicitly — that the
  first release carrying an appcast is the first one users can update *to*; users on 0.3.0
  update by hand or `brew upgrade` one last time. There is no release checklist in
  `TRACKER.md` to amend; the build-number reminder lives in `AGENTS.md:37` and the
  `release.sh` header (steps 8 and 10).
- `CHANGELOG.md` `[Unreleased]` → **Added**: *"Squatter can now update itself. It asks
  once whether it may check for updates; when one is found, a dot appears on the Settings
  gear and Settings › About offers Install Update. You can turn automatic checks on or off in
  Settings."* and → **Changed**: *"Check for Updates in Settings now checks from inside the
  app instead of opening the Releases page."*

**Verify** (one grep, case-insensitive so it covers every line above):
`grep -rni 'no network calls at all\|no third-party dependencies\|zero third-party\|no third-party deps\|Sparkle-free\|never connects to the internet\|No network, no telemetry\|No Keychain, network\|makes no network calls' README.md AGENTS.md PROJECT_SPEC.md rules/ Squatter/` → no output, exit 1;
`git status --short` lists only in-scope files (plus `?? Squatter.xcodeproj/project.xcworkspace/xcshareddata/` for the new `Package.resolved`).

## Test plan

- `SquatterTests/SettingsModelTests.swift` — five new tests listed in step 6, one edited.
  Pattern: the existing tests in that file (inject fakes through `init`, assert on the
  recorder).
- `SquatterTests/SnapshotTests.swift` — no new test; the settings snapshot now renders the
  "available" state so the new row is eyeballed on every run.
- Not testable here, and said so: Sparkle's own network, download, and install path. That
  is verified by the owner on the first real release (see Owner follow-ups) — a 0.3.0 → 0.4.0
  update on a real Mac is the only test that counts.
- Verification: full suite → `Test run with 135 tests in 11 suites passed`, both with
  the normal signing and with CI's ad-hoc settings.

## Done criteria

ALL must hold:

- [ ] `xcodegen generate && git diff --exit-code -- Squatter.xcodeproj` → exit 0 (so `Updater.swift` is in the committed project)
- [ ] `Squatter.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` exists, pins `2.9.6`, and is **not** ignored (`git check-ignore -q Squatter.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved; echo $?` → `1`)
- [ ] `grep -A1 SUPublicEDKey Squatter/Info.plist` shows a 44-character base64 key equal to `generate_keys -p --account <chosen account>`; `grep -c PLACEHOLDER project.yml` → `0`
- [ ] `grep -n 'SPARKLE_ACCOUNT=' scripts/release.sh` shows the account the owner chose in step 3
- [ ] `grep -c SUEnableAutomaticChecks Squatter/Info.plist` → `0`; `grep -c SUEnableSystemProfiling Squatter/Info.plist` → `1`
- [ ] Build → `** BUILD SUCCEEDED **`; built app contains `Contents/Frameworks/Sparkle.framework`
- [ ] Test → `** TEST SUCCEEDED **`, 135 tests; CI-style test → `** TEST SUCCEEDED **`
- [ ] `grep -rn 'URLSession\|URLRequest\|dataTask' Squatter/` → no matches (Squatter's own code still makes no request)
- [ ] `grep -n 'SquatterApp\|XCTestConfigurationFilePath' Squatter/SquatterApp.swift` shows the updater is not started under tests
- [ ] `Squatter/Squatter.entitlements` unchanged (`git diff --quiet -- Squatter/Squatter.entitlements`)
- [ ] `bash -n scripts/release.sh` → 0; `==> Appcast` stage sits after `stapler staple "$DMG"`; the public-key equality check and the `sparkle:edSignature` grep are both present
- [ ] `cask.yml` parses, refuses a release without a signed appcast, and exports `TAG` in the guard step (step 9's two grep counts hold)
- [ ] The doc grep in step 10 returns no matches
- [ ] `scripts/run-debug.sh` was run and the Settings changes were seen in the running app
- [ ] `TRACKER.md` and `CHANGELOG.md` updated; nothing committed, nothing pushed, Linear untouched
- [ ] `plans/README.md` status row for 013 updated

## STOP conditions

Stop and report if:

- The code at any "Current state" location does not match its excerpt.
- Package resolution cannot find Sparkle `2.9.6` (step 2). Do not pin a different version.
- The Keychain check in step 3a does not print `"acct"<blob>="ed25519"` — the Keychain
  changed since this plan was written, and the owner's answer may change with it.
- No user is available to answer step 3b. The key choice is the owner's; do not default it.
- `generate_keys` fails, prints something other than a 44-character key, or the Keychain
  refuses access. Do not try `-f` or a key file to work around it, and do not use any
  `--account` other than the one the owner chose.
- `generate_keys -p` prints a key that differs from a real `SUPublicEDKey` **already
  present** in `project.yml` (only the placeholder is there today; if a real key appears,
  another agent or the owner has been here — do not overwrite it).
- The build fails with a message about `nonisolated` requirements, `Sendable`, or actor
  isolation in `Updater.swift`. The shape given compiles on Xcode 26.6 / Sparkle 2.9.6; a
  failure means a different toolchain or a drifted Sparkle — report the exact error.
- The build or test fails with a `dyld` / "Library Validation" / "different Team IDs" error.
  Do **not** add an entitlement or disable the hardened runtime; report it.
- Running the tests shows Sparkle's permission dialog, or `Test run` reports a test that
  hung. That means the updater started under XCTest — the guard in `SquatterApp.init` is
  not working; report rather than adding sleeps or retries.
- You are tempted to set `SUEnableAutomaticChecks` or `SUAutomaticallyUpdate`, to host the
  appcast anywhere other than a release asset, or to move signing into CI.
- The snapshot suite fails on `settings.png` dimensions (the row must fit in 320x480 — if it
  does not, report the rendered height rather than shrinking the frame).

## Maintenance notes

- **`CURRENT_PROJECT_VERSION` must go up on every release.** Sparkle compares
  `sparkle:version` = `CFBundleVersion`, not the marketing version. A release that reuses a
  build number is invisible to installed copies. Step 10 writes this into `AGENTS.md:37`
  and step 8 into the `release.sh` header — there is no separate release checklist.
- **The key is shared with GhostCursor if the owner chose option 1.** Then neither
  project may rotate, delete or re-import the `ed25519` Keychain item without the other
  noticing; `release.sh`'s public-key equality check is what notices. If the owner chose
  option 2, the two `--account "$SPARKLE_ACCOUNT"` flags in `release.sh` are the only place
  the account name lives — keep it that way.
- **Release notes are embedded, not linked.** The appcast carries the CHANGELOG section as
  `<description sparkle:format="markdown">`; Sparkle renders it in its update dialog. If a
  section ever grows past what a dialog can show, `--full-release-notes-url` already points
  at the full CHANGELOG on GitHub.
- **The automatic-checks toggle is a pass-through.** `SettingsModel.automaticUpdateChecks`
  reads and writes Sparkle's own setting; nothing observable changes on set. That is fine
  for a toggle (the control holds its state and every render re-reads Sparkle), but do not
  bind anything else to it expecting a re-render — mirror it into tracked state first.
- **The private key is a single point of failure.** If it is lost, every installed copy
  keeps trusting the old public key and no future release can be delivered through Sparkle —
  only a manual reinstall recovers them. The owner follow-up below (export and store in a
  password manager) is not optional.
- **`releases/latest` skips pre-releases and drafts.** Marking a GitHub release as a
  pre-release keeps it out of the feed — a free beta channel, and also a footgun: a
  "latest" release published without `appcast.xml` leaves Sparkle reading a 404 until the
  next one. `cask.yml` refuses to bump Homebrew for such a release, which is the loud
  failure you want; watch that job on every release.
- **Every Sparkle-facing string is Sparkle's.** The update alert, release notes window,
  and permission prompt are Sparkle UI, not ours; the ux-writing rules do not apply to them
  and there is nothing to localize.
- **Deferred deliberately:** `SURequireSignedFeed` (2.9+, signs the appcast itself — worth
  turning on once one release has proven the pipeline; `generate_appcast` already signs the
  feed when the key is available), a shorter `SUScheduledCheckInterval` (the default is a
  day; fine for a menu bar tool), delta updates (pointless at 2 MB), and a menu bar badge
  beyond the gear dot.
- **Reviewer focus:** (1) the ordering in `release.sh` — appcast after staple; (2) that no
  test constructs `SparkleUpdater(startingUpdater: true)`; (3) that `SUEnableAutomaticChecks`
  is absent from `Info.plist`; (4) the copy in the Settings footer is honest; (5) that
  `Squatter.xcodeproj` was regenerated after `Updater.swift` was created and the
  `project-sync` check passes; (6) that `cask.yml`'s guard step exports `TAG`.

## Owner follow-ups (not for the executor)

0. **Answer step 3b** — share GhostCursor's Sparkle key (recommended) or give Squatter its
   own under Keychain account `squatter`. Writing the answer into the blank in step 3b
   lets the executor skip the question.
1. **Back up the private key now**: `generate_keys -x <file outside the repo>` (add
   `--account squatter` if you chose a dedicated key), put the file's contents in a
   password manager, delete the file. Without this, losing the Mac loses every user's
   update path — for GhostCursor too, if the key is shared and was never backed up.
2. Add `auto_updates true` to `Casks/squatter.rb` in `National-Idea-LLC/homebrew-tap` (after
   `app "Squatter.app"`), so `brew upgrade` knows the app updates itself.
3. Cut **0.4.0** with `CURRENT_PROJECT_VERSION` 5, run `scripts/release.sh --notarize`, and
   publish the DMG and `appcast.xml` as assets of the same release (the script prints the
   `gh release create` line). Then the only test that matters: install 0.4.0 on a Mac,
   publish a 0.4.1, and watch 0.4.0 offer it. Users on 0.3.0 and earlier update by hand
   one last time.
4. Create the Linear issue for this plan (milestone M3, In Review) and link it from the
   `TRACKER.md` line.
