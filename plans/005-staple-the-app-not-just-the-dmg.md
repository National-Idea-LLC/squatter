# Plan 005: Staple the notarization ticket to the app, not just the DMG

> **Notion tracking — 2026-09-06:** Current task tracking is in Notion: [Squatter](https://app.notion.com/p/3d3cacb0997081acbbbbfc2bd0f0ddf8), [Tasks](https://app.notion.com/p/3d2cacb09970808d99b7f3c0c0a36f35). Any Linear URLs, IDs, statuses or refusals below are historical references. Resolve migrated IDs via `Linear ID` and verify `Project`; use the Notion task page for all new updates. This supersedes instructions below to create, query, update or close Linear issues. Follow the current repository tracking rule, including its owner-review requirements.

> **Executor instructions**: Follow this plan step by step. Run every verification
> command and confirm the expected result before moving to the next step. If anything
> in the "STOP conditions" section occurs, stop and report — do not improvise. Do NOT
> update `plans/README.md`; the reviewer maintains the index.
>
> **Drift check (run first)**:
> `git diff --stat 721b361..HEAD -- scripts/release.sh`
> If it changed since this plan was written, compare the "Current state" excerpt below
> against the live file before proceeding; on a mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: bug (distribution)
- **Planned at**: commit `721b361`, 2026-08-28

## Why this matters

`scripts/release.sh` staples the notarization ticket to the **DMG** and never to the
**app bundle inside it**. Stapling attaches the ticket to a specific artifact; it does not
propagate to what is copied out.

Measured on the shipped v0.1.1 build, after installing via Homebrew (which extracts the app
from the DMG into `/Applications`):

```
$ xcrun stapler validate /Applications/Squatter.app
Processing: /Applications/Squatter.app
Squatter.app does not have a ticket stapled to it.
```

Gatekeeper still passed on that machine — `spctl` reported `accepted, source=Notarized
Developer ID` — but only because it could reach Apple's notary service and verify online.
**A user whose Mac is offline, behind a captive portal, or on a restricted network at first
launch gets the app blocked**, with the usual "cannot be opened because the developer cannot
be verified" dialog. That is the exact scenario stapling exists to prevent.

This affects every install path that copies the app out of the DMG — including the `brew
install --cask` path the README advertises, and any user who drags the app to Applications
and later deletes the DMG.

After this plan, the ticket is stapled to the `.app` before the DMG is built, so the app
carries its own ticket wherever it ends up, and the DMG keeps its ticket too.

## Current state

`scripts/release.sh`, lines 67-83 (verified at `721b361`). Note the ordering: the DMG is
built from `$EXPORT/$APP` at line 70, and notarization does not happen until line 76 —
**after** the app has already been copied into the DMG.

```bash
echo "==> DMG"
STAGE="$BUILD/dmg"
mkdir -p "$STAGE"
cp -R "$EXPORT/$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Squatter" -srcfolder "$STAGE" -ov -format UDZO "$DMG" -quiet
codesign --sign "Developer ID Application" --timestamp "$DMG"

if [[ "$NOTARIZE" == true ]]; then
  echo "==> Notarize"
  xcrun notarytool submit "$DMG" --keychain-profile "$KEYCHAIN_PROFILE" --wait
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
  spctl -a -t open --context context:primary-signature -v "$DMG"
else
  echo "==> Skipping notarization (pass --notarize once credentials exist)"
fi
```

Relevant variables, defined earlier in the same script:
- `BUILD` — the build output directory, wiped at the start of every run
- `EXPORT="$BUILD/export"` — where `xcodebuild -exportArchive` puts the signed app
- `APP="Squatter.app"`
- `DMG="$BUILD/Squatter-$VERSION.dmg"`
- `KEYCHAIN_PROFILE="squatter"`
- `NOTARIZE` — `true` only when the script was invoked with `--notarize`

### The fix in one sentence

Notarize and staple the **app** first, then build the DMG from the stapled app, then notarize
and staple the DMG. Two submissions, not one.

### Conventions you must match

Inlined from `AGENTS.md` — you have not read it:

- `scripts/release.sh` runs under `set -euo pipefail`. Every command must succeed or the
  script must exit; do not add `|| true` anywhere.
- Stage banners are `echo "==> Stage name"`, sentence case after the arrow. Match exactly.
- **Never spawn a shell from app code** — irrelevant here, this *is* a shell script, but do
  not add anything that downloads or executes remote content.
- Tooling and release-script changes are **not** user-visible: `TRACKER.md` gets an entry,
  `CHANGELOG.md` does **not**.
- No third-party tools. `xcrun`, `codesign`, `hdiutil`, `spctl` only.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Syntax check | `bash -n scripts/release.sh` | exit 0, no output |
| Full release (see STOP conditions before running) | `scripts/release.sh --notarize` | exit 0; two "Accepted" statuses |
| Verify app ticket | `xcrun stapler validate build/export/Squatter.app` | `The validate action worked!` |
| Verify DMG ticket | `xcrun stapler validate build/Squatter-<version>.dmg` | `The validate action worked!` |

## Scope

**In scope**:
- `scripts/release.sh`
- `TRACKER.md`

**Out of scope** (do NOT touch):
- `Casks/squatter.rb` — plan 006 owns that file. Do not bump its version or sha256 here.
- `project.yml`, `MARKETING_VERSION` — this plan does not cut a release or change the version.
- `.github/workflows/ci.yml` — CI does not sign or notarize and must not start.
- `CHANGELOG.md` — not user-visible.
- The signing, verification and sandbox-check block at lines 55-65. It is correct.

## Git workflow

**Do not commit.** This repo gates commits behind owner approval (`rules/core-workflow.md`).
Leave the change in the working tree and report. Do not `git add`, commit, push, or tag.
Do not update Linear — note in your report that `TRACKER.md` changed.

## Steps

### Step 1: Notarize and staple the app before the DMG is built

In `scripts/release.sh`, insert a new stage **immediately before** the `echo "==> DMG"` line.
Notarization requires a zip container for a bare `.app` — `notarytool` cannot take a bundle
directly — so this zips the app to a throwaway path, submits that, and staples the original
bundle:

```bash
if [[ "$NOTARIZE" == true ]]; then
  echo "==> Notarize app"
  # The ticket must be stapled to the app itself, not only to the DMG: stapling does not
  # follow a bundle that is copied out of the disk image. Without this, `brew install
  # --cask` (which extracts the app) leaves an unstapled app that only passes Gatekeeper
  # on a machine that can reach Apple's notary service.
  ditto -c -k --keepParent "$EXPORT/$APP" "$BUILD/Squatter-app.zip"
  xcrun notarytool submit "$BUILD/Squatter-app.zip" --keychain-profile "$KEYCHAIN_PROFILE" --wait
  xcrun stapler staple "$EXPORT/$APP"
  xcrun stapler validate "$EXPORT/$APP"
  rm -f "$BUILD/Squatter-app.zip"
fi
```

`ditto -c -k --keepParent` is the Apple-documented way to archive a bundle for notarization;
`zip -r` does not reliably preserve symlinks and extended attributes in a bundle. Do not
substitute it.

**Verify**: `bash -n scripts/release.sh` → exit 0, no output.

### Step 2: Confirm the DMG is built from the now-stapled app

No edit should be needed — the existing `cp -R "$EXPORT/$APP" "$STAGE/"` already copies from
`$EXPORT`, which step 1 has just stapled in place.

**Verify by reading**: confirm the `cp -R "$EXPORT/$APP" "$STAGE/"` line appears **after**
your new block. If it does not, you inserted the block in the wrong place — move it.

`grep -n 'Notarize app\|cp -R "\$EXPORT/\$APP"\|==> DMG' scripts/release.sh` → three lines, in
that order. **Escape the `$`** — unescaped inside the double quotes the shell expands
`$EXPORT` and `$APP` to empty strings and the `cp` line silently never matches, making a
correct edit look like a failed one.

### Step 3: Leave the DMG notarization exactly as it is

The existing `if [[ "$NOTARIZE" == true ]]` block that submits and staples `$DMG` stays.
Both artifacts get their own ticket; that is intended, not redundant. Do not merge the two
blocks or make the second conditional on the first.

**Verify**: `grep -c "xcrun stapler staple" scripts/release.sh` → `2`.

### Step 4: Update the tracking doc

`TRACKER.md` — add at the **top** of the "Dev changelog" list:

```
- **2026-08-28** — `scripts/release.sh` now notarizes and staples the app bundle before building the DMG, then staples the DMG as before. Previously only the DMG carried a ticket, so any install path that copies the app out of it — `brew install --cask`, or dragging to Applications and deleting the DMG — left an app that only passed Gatekeeper on a machine that could reach Apple's notary service; offline first launch would have been blocked. Verified against the shipped v0.1.1, where `stapler validate` on the installed app reported no ticket.
```

Do **not** touch `CHANGELOG.md`.

**Verify**: `grep -c "staples the app bundle" TRACKER.md` → `1`.

## Test plan

There is nothing to unit-test — this is a release script. Verification is the artifacts:

- `bash -n scripts/release.sh` → exit 0.
- The ordering grep in step 2.
- `grep -c "xcrun stapler staple" scripts/release.sh` → `2`.

**A full `scripts/release.sh --notarize` run is the real proof, but do not run it yourself** —
see STOP conditions. It builds and signs a DMG, submits two artifacts to Apple, and takes
several minutes. Say clearly in your report that the end-to-end run has NOT been performed
and is the owner's step.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `bash -n scripts/release.sh` exits 0
- [ ] `grep -c "xcrun stapler staple" scripts/release.sh` → `2`
- [ ] `grep -c "ditto -c -k --keepParent" scripts/release.sh` → `1`
- [ ] `grep -n 'Notarize app\|cp -R "\$EXPORT/\$APP"\|==> DMG' scripts/release.sh` returns three
      lines in that order (escape the `$`, or the `cp` line will not match)
- [ ] `grep -c "staples the app bundle" TRACKER.md` → `1`
- [ ] `git status --porcelain` lists only `scripts/release.sh` and `TRACKER.md`, nothing staged
      or committed

## STOP conditions

Stop and report back (do not improvise) if:

- **You are tempted to run `scripts/release.sh --notarize` to prove the change.** Do not. It
  signs and publishes-adjacent artifacts, contacts Apple twice with the owner's credentials,
  and takes minutes. The owner runs it. Report that verification is pending.
- `scripts/release.sh` at `721b361` does not match the "Current state" excerpt.
- The script already contains a second `xcrun stapler staple` — the fix has landed independently.
- `ditto` is unavailable, or you conclude a bare `.app` can be submitted to `notarytool`
  without zipping it. It cannot; report rather than working around it.

## Maintenance notes

- Two notarization submissions per release means two round trips to Apple — roughly a minute
  each. That is the cost of a correct offline first launch; do not "optimize" it back to one.
- A reviewer should confirm the app is stapled **before** `hdiutil create` runs. If the order
  is ever reversed, everything still appears to work — both `stapler validate` calls pass, the
  DMG is fine — and the bug silently returns for anyone extracting the app. The ordering grep
  in step 2 is the only guard.
- Related, deliberately out of scope: this whole pipeline runs on one machine with a local
  keychain profile. A tag-triggered workflow that archives, notarizes and uploads is still
  unbuilt (Linear E2-188).
- If a future release ever ships a `.pkg` instead of a DMG, the same rule applies: staple the
  innermost artifact the user ends up running.
