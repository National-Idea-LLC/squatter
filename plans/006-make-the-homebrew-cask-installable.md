# Plan 006: Make the Homebrew cask actually installable

> **Notion tracking — 2026-09-06:** Current task tracking is in Notion: [Squatter](https://app.notion.com/p/3d3cacb0997081acbbbbfc2bd0f0ddf8), [Tasks](https://app.notion.com/p/3d2cacb09970808d99b7f3c0c0a36f35). Any Linear URLs, IDs, statuses or refusals below are historical references. Resolve migrated IDs via `Linear ID` and verify `Project`; use the Notion task page for all new updates. This supersedes instructions below to create, query, update or close Linear issues. Follow the current repository tracking rule, including its owner-review requirements.

> **Executor instructions**: Follow this plan step by step. Run every verification
> command and confirm the expected result before moving to the next step. If anything
> in the "STOP conditions" section occurs, stop and report — do not improvise. Do NOT
> update `plans/README.md`; the reviewer maintains the index.
>
> **This plan contains an owner decision (step 1) that is NOT yours to make.** Read the
> whole plan before touching anything.
>
> **Drift check (run first)**:
> `git diff --stat 721b361..HEAD -- Casks/squatter.rb README.md`
> On a mismatch with the excerpts below, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: M (S for the parts an executor can do alone)
- **Risk**: LOW
- **Depends on**: none
- **Category**: bug (distribution) + dx
- **Planned at**: commit `721b361`, 2026-08-28

## Why this matters

`README.md:35` — on a public repo, for a released app — tells every user to run:

```sh
brew install --cask National-Idea-LLC/tap/squatter
```

**That command cannot work. The tap does not exist.**

```
$ gh repo view National-Idea-LLC/homebrew-tap
GraphQL: Could not resolve to a Repository with the name 'National-Idea-LLC/homebrew-tap'.
```

Homebrew resolves `National-Idea-LLC/tap/squatter` to the repository
`github.com/National-Idea-LLC/homebrew-tap`, looking for `Casks/squatter.rb` inside it. The
cask file exists only in the app repo, and Homebrew will not install a cask from a loose path:

```
$ brew info --cask ./Casks/squatter.rb
Error: Homebrew requires casks to be in a tap, rejecting:
  ./Casks/squatter.rb
```

So the advertised install method fails for everyone. The DMG download link in the same README
section works fine, which is probably why nobody has noticed.

Separately, the cask emits a deprecation warning on **every** Homebrew operation:

```
Warning: Calling string comparison format for `depends_on macos:` is deprecated!
Use `depends_on macos: :sequoia` instead.
  Casks/squatter.rb:11
```

The cask itself is otherwise correct — verified by installing it from a scratch local tap:
Homebrew's own sha256 check passed against the published v0.1.1 DMG, the app installed to
`/Applications` at version 0.1.1, and `spctl` reported `accepted, source=Notarized Developer ID`.
The artifact is good; only its *distribution* is broken.

## Current state

### `Casks/squatter.rb` — the whole file, verified at `721b361`

```ruby
cask "squatter" do
  version "0.1.1"
  sha256 "c5c435a3abe19af23d0eeb9dec31fd63ba026d5bfac8634b65a5359ba6a6954f"

  url "https://github.com/National-Idea-LLC/squatter/releases/download/v#{version}/Squatter-#{version}.dmg",
      verified: "github.com/National-Idea-LLC/squatter/"
  name "Squatter"
  desc "Menu bar app that shows which process is listening on each port"
  homepage "https://github.com/National-Idea-LLC/squatter"

  depends_on macos: ">= :sequoia"

  app "Squatter.app"

  zap trash: [
    "~/Library/Preferences/sa.ni.squatter.plist",
  ]
end
```

The `version`/`sha256` pair is correct for the shipped v0.1.1 and was verified by downloading
the published asset and comparing hashes. **Do not change either value in this plan.**

### `README.md:32-38` — the Install section

```markdown
## Install

```sh
brew install --cask National-Idea-LLC/tap/squatter
```

Or download the DMG from [Releases](https://github.com/National-Idea-LLC/squatter/releases), drag Squatter to Applications, and launch it. The build is signed with a Developer ID and notarized by Apple.
```

### Conventions you must match

- **UI/docs copy**: sentence case in prose, no marketing language. The README is terse and
  factual; match it.
- Tooling and packaging changes are **not** user-visible in the app sense: `TRACKER.md` gets an
  entry, `CHANGELOG.md` does **not**. (`CHANGELOG.md` is for changes to the app itself.)
- No third-party tools.

## Commands you will need

| Purpose | Command | Expected |
|---------|---------|----------|
| Cask style | `brew style Casks/squatter.rb` | exit 0 (may still refuse outside a tap — see step 2) |
| Scratch-tap install test | see step 4 | app appears in `/Applications` at 0.1.1 |

## Scope

**In scope**:
- `Casks/squatter.rb` (step 2 only — the `depends_on` line)
- `TRACKER.md`

**Out of scope** (do NOT touch):
- `Casks/squatter.rb`'s `version` and `sha256` — verified correct against the published asset.
- `scripts/release.sh` — plan 005 owns it.
- Creating a GitHub repository. An executor must never create a public repo; that is the
  owner's action even once the decision in step 1 is made.
- The DMG-download paragraph in the README. It is accurate and is the working fallback.
- **`README.md` entirely.** Step 1 resolved to option (a), under which the existing install
  line is already correct. Nothing in that file needs to change.

## Git workflow

**Do not commit.** Leave changes in the working tree and report. No `git add`, commit, push,
or tag. Do not update Linear.

## Steps

### Step 1: OWNER DECISION — ANSWERED 2026-08-29 → option (a)

> **Decision: create `National-Idea-LLC/homebrew-tap`.** The owner chose the conventional
> Homebrew path — a separate `homebrew-*` tap repo — which is exactly what `README.md:35`
> already advertises. Consequences for the rest of this plan:
>
> - **Step 3 becomes a no-op.** Leave `README.md:35` exactly as it is; it becomes correct the
>   moment the tap repo exists. `README.md` is now **out of scope** — do not edit it.
> - **Creating the repository is still the owner's action, not an executor's.** Never run
>   `gh repo create` or equivalent. Its absence is expected, not a failure.
> - Steps 2, 4 and 5 proceed unchanged.
>
> Rationale, recorded so it is not re-litigated: (b) tapping this repo directly has no sync
> cost but an unfamiliar two-line install and makes `brew update` re-fetch the whole app repo;
> (c) dropping the cask loses `brew upgrade` for users. (a) is what nearly every project ships
> and what the README already promises. Its one real cost — the cask's `version`/`sha256`
> drifting in a second repo — is manual only until the tag-triggered release workflow
> (Linear E2-188) pushes the bump automatically. See Maintenance notes.
>
> The endgame is neither: submission to `homebrew/cask` core, where `brew install --cask
> squatter` works with no tap at all. That has notability requirements Squatter does not meet
> yet, so it is a later move.

The three options as originally posed, kept as the record of what was weighed:

**(a) Create `National-Idea-LLC/homebrew-tap`** (matches what the README already claims).
A new public repo containing `Casks/squatter.rb`. The README line then works unchanged.
Cost: a second repo to keep in sync on every release — `scripts/release.sh` would need to
push the updated cask there, or the owner does it by hand and it silently rots.

**(b) Serve the tap from this repo.** Homebrew also accepts
`brew tap National-Idea-LLC/squatter https://github.com/National-Idea-LLC/squatter` followed
by `brew install --cask squatter`, reading `Casks/` from the app repo itself. No second repo,
no sync problem. Cost: a two-line install instruction instead of one, and a non-standard
tap name.

**(c) Drop the cask entirely.** Delete `Casks/squatter.rb` and the brew line from the README;
DMG download becomes the only documented path. Cost: no `brew upgrade` for users. Honest, and
the least machinery — the project's stated value is minimalism.

Each changes what users type and what the release process must maintain. **Resolved: (a).**

### Step 2: Fix the deprecated `depends_on` syntax — safe to do regardless

This is independent of step 1 and can land on its own. In `Casks/squatter.rb`, line 11:

```ruby
  depends_on macos: ">= :sequoia"
```

becomes:

```ruby
  depends_on macos: :sequoia
```

`depends_on macos: :sequoia` already means "Sequoia or later" in Homebrew's cask DSL — the
symbol form is a minimum, not an exact match. This is a syntax modernisation with no
behavioural change; macOS 15 remains the floor, matching `MACOSX_DEPLOYMENT_TARGET` in
`project.yml` and the "macOS 15 or later" line in the README.

**Verify**:
- `grep -n "depends_on" Casks/squatter.rb` → exactly one line, reading `  depends_on macos: :sequoia`
- `grep -c '">= :sequoia"' Casks/squatter.rb` → `0`

### Step 3: README — NOTHING TO DO

Step 1 resolved to option (a), so `README.md:35` is already the correct command. Do not touch
`README.md`. It is listed under "Out of scope" for exactly this reason.

**Verify**: `git status --porcelain README.md` → empty.

### Step 4: Prove the cask installs, using a scratch tap

Regardless of step 1, verify the cask file itself is installable. This uses a throwaway local
tap and cleans up after itself. It installs Squatter to `/Applications` and then removes it —
**if `/Applications/Squatter.app` already exists, STOP** rather than clobbering it.

```sh
ls -d /Applications/Squatter.app 2>/dev/null && { echo "Squatter already installed — STOP"; exit 1; }
brew tap-new local/squattercheck --no-git
cp Casks/squatter.rb "$(brew --repository)/Library/Taps/local/homebrew-squattercheck/Casks/"
brew install --cask local/squattercheck/squatter
defaults read /Applications/Squatter.app/Contents/Info.plist CFBundleShortVersionString
spctl -a -vv -t exec /Applications/Squatter.app
brew uninstall --cask local/squattercheck/squatter
brew untap local/squattercheck
```

**Expected**: version prints `0.1.1`; `spctl` prints `accepted` and `source=Notarized Developer ID`;
no deprecation warning appears anywhere in the output (that is the real check on step 2); and
after the last two commands `/Applications/Squatter.app` is gone and the tap is removed.

**Note**: `stapler validate` on the installed app will still report no ticket. That is plan
005's bug, not this one. Do not attempt to fix it here.

### Step 5: Update the tracking doc

`TRACKER.md` — add at the **top** of the "Dev changelog" list. Adjust the second sentence to
match what you actually did in step 3:

```
- **2026-08-29** — Fixed the deprecated `depends_on macos:` string form in `Casks/squatter.rb`, which made Homebrew warn on every operation. Also recorded that the README's advertised `brew install --cask National-Idea-LLC/tap/squatter` cannot work yet: the `homebrew-tap` repository does not exist and Homebrew refuses a cask outside a tap, so the only working install path today is the DMG download. The owner has chosen to create `National-Idea-LLC/homebrew-tap`, which makes the README line correct without changing it; publishing that repo, and keeping the cask's version and sha256 in sync with each release, is the remaining work.
```

**Verify**: `grep -c "homebrew-tap" TRACKER.md` → `1`.

## Test plan

No unit tests — this is packaging. Verification is step 4's scratch-tap install plus:

- `grep -n "depends_on" Casks/squatter.rb` → the symbol form, once
- No `Warning: Calling string comparison format` anywhere in step 4's output

## Done criteria

- [ ] `grep -c 'depends_on macos: :sequoia' Casks/squatter.rb` → `1`
- [ ] `grep -c '">= :sequoia"' Casks/squatter.rb` → `0`
- [ ] `grep -n "version\|sha256" Casks/squatter.rb` still shows `0.1.1` and
      `c5c435a3abe19af23d0eeb9dec31fd63ba026d5bfac8634b65a5359ba6a6954f`, unchanged
- [ ] Step 4 completes, prints `0.1.1` and `accepted`, emits no deprecation warning, and leaves
      `/Applications/Squatter.app` absent and the scratch tap untapped
- [ ] `grep -c "homebrew-tap" TRACKER.md` → `1`
- [ ] `git status --porcelain` lists only `Casks/squatter.rb` and `TRACKER.md` — nothing else
      modified, nothing staged or committed

## STOP conditions

Stop and report back (do not improvise) if:

- **You are about to change `README.md`.** Don't. Step 1 resolved to option (a), under which
  the file is already correct.
- **You are about to create a GitHub repository.** Never. Report instead.
- `/Applications/Squatter.app` already exists before step 4 — the owner has it installed and
  the test would clobber their copy.
- Step 4's install fails a checksum. That would mean the published v0.1.1 asset changed since
  it was verified, which is serious — report the observed hash, change nothing.
- You conclude the `version`/`sha256` need bumping. They do not; they match the shipped
  release. Bumping them belongs to whatever cuts the next version.

## Maintenance notes

- **Option (a) was chosen, so the sync problem is now the thing to watch.** The cask's
  `version` and `sha256` must change on every release, and the canonical copy will live in a
  *different repo* (`National-Idea-LLC/homebrew-tap`). Today that is manual — it was done by
  hand for 0.1.1. When it drifts, `brew install` hands users the previous DMG and fails with a
  checksum mismatch, and it fails for everyone at once. Automating the cask bump belongs with
  the tag-triggered release workflow (Linear E2-188); until that exists, treat "push the cask
  bump to homebrew-tap" as a mandatory step of cutting a release.
- **Decide which copy of `Casks/squatter.rb` is canonical.** Keeping it in both repos invites
  exactly the drift above. Either delete it here once the tap repo exists, or make the release
  workflow copy this one into the tap so this repo stays the source of truth.
- A reviewer should confirm `version` and `sha256` are byte-identical to before. The single
  most damaging mistake available in this file is a hash that does not match the published
  asset — every user's install breaks at once, with a scary-looking checksum error.
- `brew style` and `brew audit --cask` are worth running before any future cask edit; both
  need the file inside a tap, so reuse step 4's scratch-tap trick.
