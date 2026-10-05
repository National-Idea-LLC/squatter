---
description: Notion task sync — keep Squatter's Notion tasks current with TRACKER.md; Linear is retired
alwaysApply: true
---

# Issue tracker (Notion)

_Keep Squatter's Notion tasks in sync with the repo. Linear is retired — never touch it._

**Project:** [Squatter](https://app.notion.com/p/3d3cacb0997081acbbbbfc2bd0f0ddf8) in the **Projects** database. Work items live in the **Tasks** database, data source `collection://3d2cacb0-9970-8015-adde-000ba9f634a7`, each with **Project** set to the Squatter page. Milestones (`M0 — Foundation`, `M1 — P0 core`, `M2 — P1 polish`, `M3 — Release`) mirror the TRACKER.md phase board.

## Task properties

- **Name:** the TRACKER task, or `Plan 0NN — <plan title>` for a plan.
- **Status:** `Not started` / `Up next` / `In progress` / `Done` / `Canceled`.
- **Team** and **Assignee:** `Elyas`. **Milestone:** the phase. **Labels:** `Bug`, `Feature`, or `Improvement`.
- **Created** / **Completed:** dates.
- `Linear ID`, `Linear URL`, `Linear Status` are history from the 2026-09-06 migration. Leave them empty on new tasks.

## Keep it updated (same commit-sized unit as TRACKER.md)

- **Starting a task:** find or create the Notion task and set it to **In progress**.
- **Finishing a task:** append what changed, the commit SHAs, and how it was verified to the task body.
- **Owner says merge, push, or ship:** set **Done** and fill **Completed**. That means they already checked the work, so don't leave the task waiting on them.
- **Release:** log the version, build number, release URL, DMG sha256, and the appcast/cask checks on every task that shipped in it.
- **Spec decisions** (resolving an Open Question in `PROJECT_SPEC.md`): note the decision on the relevant task.
- Never bulk-edit or delete tasks.

## Plans (`plans/`)

- **Every plan has a task.** When a plan is written under `plans/`, create its Notion task in the same session (body: why it matters, scope, the plan path, the commit it was planned at). Set it to **In progress** when an executor is dispatched and **Done** when it merges. Put the task link in the plan's row in `plans/README.md`.
- A plan without a task is a reconcile finding.
