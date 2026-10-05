# Plan 004: Make `project.yml` provably the source of truth for the Xcode project

> **Notion tracking — 2026-09-06:** Current task tracking is in Notion: [Squatter](https://app.notion.com/p/3d3cacb0997081acbbbbfc2bd0f0ddf8), [Tasks](https://app.notion.com/p/3d2cacb09970808d99b7f3c0c0a36f35). Any Linear URLs, IDs, statuses or refusals below are historical references. Resolve migrated IDs via `Linear ID` and verify `Project`; use the Notion task page for all new updates. This supersedes instructions below to create, query, update or close Linear issues. Follow the current repository tracking rule, including its owner-review requirements.

> **Executor instructions**: Follow this plan step by step. Run every verification
> command and confirm the expected result before moving to the next step. If anything
> in the "STOP conditions" section occurs, stop and report — do not improvise. When
> done, update the status row for this plan in `plans/README.md`.
>
> **Drift check (run first)**:
> `git diff --stat 9c7eef2..HEAD -- .github/workflows/ci.yml scripts/release.sh project.yml AGENTS.md`
> If any of those changed since this plan was written, compare the "Current state" excerpts
> below against the live files before proceeding; on a mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none (independent of plans 001–003; can run in any order)
- **Category**: dx
- **Planned at**: commit `9c7eef2`, 2026-08-28

## Why this matters

`AGENTS.md` states the rule plainly: "`Squatter.xcodeproj` … the project file is committed;
`project.yml` is its source of truth — never hand-edit the `.pbxproj`". Targets, build
settings, `Info.plist` keys, entitlements, the deployment target, the bundle identifiers,
`SWIFT_STRICT_CONCURRENCY: complete`, `ENABLE_APP_SANDBOX: NO` and the hardened-runtime flag
all live in `project.yml`.

Nothing enforces any of it. Xcode writes to the `.pbxproj` whenever a file is added or a
setting is nudged in its UI, and neither CI nor `scripts/release.sh` ever regenerates or
compares. The two files can diverge silently, and the divergence would be invisible until
someone regenerated and got a surprise diff — or, worse, until a release shipped with a
setting that `project.yml` says is off. For an app whose security posture is *defined* by
build settings (`ENABLE_APP_SANDBOX: NO` is deliberate; hardened runtime on is load-bearing
for notarization), "the committed project file might not match its spec" is a real gap.

After this plan: CI fails on any divergence, and `scripts/release.sh` regenerates before it
archives, so a release is always built from `project.yml`.

The check passes as of commit `9c7eef2` with xcodegen 2.46.0 — verified, there is no existing
drift to clean up first.

## Current state

### `.github/workflows/ci.yml` — the whole file

```yaml
name: CI

on:
  pull_request:
  push:
    branches: [main]

concurrency:
  group: ci-${{ github.ref }}
  cancel-in-progress: true

permissions:
  contents: read

jobs:
  test:
    name: Build & test (macOS)
    runs-on: macos-26
    timeout-minutes: 30
    steps:
      - uses: actions/checkout@v4

      - name: Select Xcode 26
        run: |
          set -euo pipefail
          XCODE=$(ls -d /Applications/Xcode_26*.app 2>/dev/null | sort -V | tail -1)
          if [ -z "$XCODE" ]; then echo "No Xcode 26 on this runner"; ls /Applications | grep Xcode; exit 1; fi
          sudo xcode-select -s "$XCODE"
          xcodebuild -version

      - name: Build and test
        run: |
          set -o pipefail
          xcodebuild \
            -project Squatter.xcodeproj \
            -scheme Squatter \
            -destination 'platform=macOS' \
            CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
            test 2>&1 | grep -vE "linkd\.autoShortcut|Process Instance Registry"
```

### `scripts/release.sh:22-37` — where regeneration belongs

```bash
cd "$(dirname "$0")/.."
VERSION=$(awk -F'"' '/MARKETING_VERSION/{print $2}' project.yml)
[[ -n "$VERSION" ]] || { echo "Couldn't read MARKETING_VERSION from project.yml"; exit 1; }
DMG="$BUILD/Squatter-$VERSION.dmg"

echo "==> Squatter $VERSION"
rm -rf "$BUILD"
mkdir -p "$BUILD"

echo "==> Tests"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -destination 'platform=macOS' test -quiet

echo "==> Archive"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
  -archivePath "$ARCHIVE" archive -quiet
```

Note the script already reads `MARKETING_VERSION` **out of `project.yml`** while building from
the `.pbxproj` — so it already treats `project.yml` as authoritative for the version but not
for anything else. That inconsistency is precisely the gap.

### `AGENTS.md` — the "Commands" list you will extend

It currently contains this bullet, among others:

```
- `xcodegen generate` — regenerate `Squatter.xcodeproj` after editing `project.yml` (the project file is committed; `project.yml` is its source of truth — never hand-edit the `.pbxproj`). Install with `brew install xcodegen`.
```

### Conventions you must match

- The CI file uses `set -euo pipefail` in multi-line `run:` blocks and pins
  `actions/checkout@v4`. Match both.
- `scripts/release.sh` runs under `set -euo pipefail` and prints stage banners as
  `echo "==> Stage name"`. Match that style exactly.
- `AGENTS.md` is the single source of agent guidance; `CLAUDE.md` only points at it. Add the
  new command to `AGENTS.md`, never to `CLAUDE.md`.
- Repo rule: CI and tooling changes are **not** user-visible. `TRACKER.md` gets an entry;
  `CHANGELOG.md` does **not**.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Regenerate (throwaway copy — see step 1) | `xcodegen generate` | exit 0 |
| Drift check | `git diff --exit-code --quiet -- Squatter.xcodeproj` | exit 0 = no drift |
| Test | `xcodebuild -project Squatter.xcodeproj -scheme Squatter -destination 'platform=macOS' test` | exit 0 |
| xcodegen version | `xcodegen --version` | `Version: 2.46.0` or later |

## Scope

**In scope**:
- `.github/workflows/ci.yml`
- `scripts/release.sh`
- `AGENTS.md` (one bullet)
- `TRACKER.md`

**Out of scope** (do NOT touch):
- `project.yml` — this plan changes nothing about what the project *contains*. If you feel a
  need to edit it to make the check pass, that is drift and a STOP condition.
- `Squatter.xcodeproj/**` — do not commit a regenerated project as part of this plan. Step 1
  proves there is nothing to regenerate; if that is false, stop and report.
- `CLAUDE.md` — it is a pointer file by design.
- `CHANGELOG.md` — tooling changes are not user-visible.
- Adding SwiftLint, a formatter, or any other new tool. `AGENTS.md` marks lint as optional
  and not required; this plan is only about `project.yml` ↔ `.pbxproj`.

## Git workflow

**Do not commit anything.** This repo gates commits behind owner approval
(`rules/core-workflow.md`). Leave changes in the working tree and report. Do not `git add`,
commit, push, or open a PR. Do not update Linear — note in your report that `TRACKER.md`
changed and the owner needs to mirror it.

## Steps

### Step 1: Prove there is no existing drift — without touching the working tree

Running `xcodegen generate` in the repo would rewrite `Squatter.xcodeproj`, which this plan
forbids. Do the check in a throwaway copy instead:

```sh
rm -rf /tmp/xcgen-check && mkdir -p /tmp/xcgen-check
cp -R "$PWD/." /tmp/xcgen-check/
cd /tmp/xcgen-check && xcodegen generate --quiet && git diff --exit-code -- Squatter.xcodeproj
```

**Verify**: the final command exits 0 and prints nothing. If it prints a diff, STOP (see STOP
conditions). Then `cd` back to the repo root and confirm `git status --porcelain` is empty
apart from any files you have already changed.

Record the version you used: `xcodegen --version`.

### Step 2: Add the CI drift check

In `.github/workflows/ci.yml`, add a second job **after** the existing `test` job, at the
same indentation level (two spaces under `jobs:`):

```yaml
  project-sync:
    name: project.yml is in sync
    runs-on: macos-26
    timeout-minutes: 15
    steps:
      - uses: actions/checkout@v4

      - name: Install xcodegen
        run: |
          set -euo pipefail
          brew install xcodegen
          xcodegen --version

      - name: Regenerate and compare
        run: |
          set -euo pipefail
          xcodegen generate
          if ! git diff --exit-code -- Squatter.xcodeproj; then
            echo
            echo "Squatter.xcodeproj does not match project.yml."
            echo "project.yml is the source of truth — run 'xcodegen generate' and commit the result."
            echo "If the diff is only cosmetic, xcodegen has been upgraded; regenerating and committing is still the fix."
            exit 1
          fi
```

Do not change the existing `test` job. The two jobs run in parallel; leaving them independent
means a project-sync failure still lets you see whether the tests pass.

**Verify**:
- `grep -c "runs-on: macos-26" .github/workflows/ci.yml` → `2`
- `grep -nE '^  [a-zA-Z_-]+:$' .github/workflows/ci.yml` → exactly four lines, ending with
  `test:` and `project-sync:`. This is an indentation check: every two-space key in this file
  belongs to `on:` (`pull_request:`, `push:`) or `jobs:`, so seeing `project-sync:` here proves
  it landed as a sibling of `test:` rather than nested inside it. Do not install a YAML parser
  to check this — nothing else in this repo depends on one.

### Step 3: Regenerate before archiving a release

In `scripts/release.sh`, insert a new stage between the `mkdir -p "$BUILD"` line and the
`echo "==> Tests"` line:

```bash
echo "==> Regenerate project"
command -v xcodegen >/dev/null || { echo "xcodegen not found — install with 'brew install xcodegen'"; exit 1; }
xcodegen generate
git diff --quiet -- Squatter.xcodeproj || echo "note: Squatter.xcodeproj was regenerated from project.yml — commit the change"
```

The regeneration is unconditional so a release is always built from `project.yml`; the diff
check only *warns*, because a release build should not be blocked by an uncommitted project
file the script itself just wrote. The blocking version of this check is CI's job.

**Verify**:
- `bash -n scripts/release.sh` → exit 0, no output (syntax check; does not run the script)
- `grep -n "==> Regenerate project" scripts/release.sh` → one match, on a line before
  `echo "==> Tests"`

Do **not** run `scripts/release.sh` — it archives, signs and builds a DMG, and step 1 already
proved the regeneration is a no-op.

### Step 4: Document the check

In `AGENTS.md`, under "## Commands", add one bullet directly after the existing
`xcodegen generate` bullet:

```
- `xcodegen generate && git diff --exit-code -- Squatter.xcodeproj` — verify the committed project matches `project.yml`. CI runs this on every PR (`project-sync` job) and `scripts/release.sh` regenerates before archiving, so a release is always built from `project.yml`.
```

**Verify**: `grep -c "project-sync" AGENTS.md` → `1`

### Step 5: Update the tracking doc

`TRACKER.md` — add at the **top** of the "Dev changelog" list:

```
- **2026-08-28** — `project.yml` is now enforced, not just declared: a `project-sync` CI job regenerates the project on every PR and fails if the committed `Squatter.xcodeproj` differs, and `scripts/release.sh` regenerates before archiving so a release can't be built from a hand-edited `.pbxproj`. Verified no existing drift against xcodegen 2.46.0.
```

Do **not** touch `CHANGELOG.md`.

**Verify**: `grep -c "project-sync" TRACKER.md` → `1`

## Test plan

There is nothing to unit-test here — the change is CI configuration and a shell script. The
verification is the drift check itself, plus proof that neither the app build nor the test
suite is affected:

- Step 1 proves the check is green today, in a throwaway copy, with the working tree untouched.
- `xcodebuild -project Squatter.xcodeproj -scheme Squatter -destination 'platform=macOS' test`
  → exit 0, same number of tests as before your changes (69 at commit `9c7eef2`; more if plans
  001–003 have already landed — record the count you see, do not assume one).
- `bash -n scripts/release.sh` → exit 0.
- The `project-sync` job itself can only be verified by pushing, which this plan does not do.
  Say so in your report.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] Step 1's throwaway-copy drift check exits 0
- [ ] `grep -nE '^  [a-zA-Z_-]+:$' .github/workflows/ci.yml` returns four lines, including
      both `test:` and `project-sync:`
- [ ] `bash -n scripts/release.sh` exits 0
- [ ] `grep -n "xcodegen generate" scripts/release.sh` returns one match, on a line before `echo "==> Tests"`
- [ ] `grep -c "project-sync" AGENTS.md` → `1`
- [ ] `xcodebuild -project Squatter.xcodeproj -scheme Squatter -destination 'platform=macOS' test` exits 0
- [ ] `git status --porcelain` lists only `.github/workflows/ci.yml`, `scripts/release.sh`,
      `AGENTS.md`, `TRACKER.md` — in particular **no** change under `Squatter.xcodeproj/` —
      and nothing is staged or committed
- [ ] `plans/README.md` status row for 004 updated

## STOP conditions

Stop and report back (do not improvise) if:

- **Step 1 reports a diff.** That means the committed `.pbxproj` has already drifted from
  `project.yml`. Do not silently commit a regenerated project: report exactly what the diff
  changes (build settings? file membership? just object IDs and a `LastUpgradeCheck`?) so the
  owner can decide whether the `.pbxproj` or `project.yml` is the one that is wrong. Landing
  this plan on top of undiagnosed drift would bake the wrong file in as the answer.
- `xcodegen` is not installed and you cannot install it. Report rather than skipping step 1 —
  a plan that adds a check nobody has run is worse than no check.
- Your local `xcodegen --version` is older than 2.46.0. The no-drift result was verified
  against 2.46.0; an older version may produce a false diff.
- Adding the `project-sync` job requires changing the existing `test` job.
- You conclude the `.pbxproj` should stop being committed. That is a real design option, but
  it is a decision for the owner (it changes how the repo is cloned and opened), not part of
  this plan.

## Maintenance notes

- **The one way this check can go falsely red**: xcodegen changes its output format between
  versions, so a runner that installs a newer xcodegen than the one used to generate the
  committed project will report a diff. The remedy is always the same and always correct —
  run `xcodegen generate` locally with the current version and commit the result. That is why
  the job's failure message says so explicitly. If this becomes frequent, pin the version by
  replacing `brew install xcodegen` with a download of a specific release tarball.
- `scripts/release.sh` warns rather than fails on a post-regeneration diff, on purpose. If you
  ever want the release path to be strict too, change the `|| echo "note: …"` to
  `|| { echo "…"; exit 1; }` — but then a release cannot proceed until the project file is
  committed, which is a workflow change the owner should choose.
- A reviewer should confirm the new job did **not** get nested inside the `test` job. The
  indentation grep in step 2 exists specifically because YAML mistakes there are easy to make
  and produce a job that silently never runs.
- Related but deliberately out of scope: CI still has no tag-triggered archive/notarize/release
  workflow — `PROJECT_SPEC.md` lists one as an assumption and every release today is built on
  one machine with a local keychain profile. That is a larger piece of work and its own plan.
