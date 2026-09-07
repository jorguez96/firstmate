---
name: task-landing
description: >-
  Load when a ship task reports a PR, before cleanup or custom checks, or when a scout completes or is promoted.
---

# Task landing

`AGENTS.md` section 7 owns merge authority and the delivery modes.
This skill owns the mechanics of finishing, after the work itself is done.

## PR ready

The ready signal depends on the selected mode.
`no-mistakes` reports `done: PR <url> checks green` after CI is green, while `direct-PR` reports `done: PR <url>` after opening the PR.

Run `bin/fm-pr-check.sh <id> <PR url>`.
It records `pr=` and the forge's `pr_head=` when available in the task's meta, and arms the watcher's merge poll.
Before treating a PR as ready, verify that its owner and repository exactly match the push remote.

Tell the captain the PR's full `https://...` URL rather than a bare `#number`, a concise outcome summary, and the no-mistakes risk level when applicable.

## Custom watcher checks

For any custom `state/<id>.check.sh` you write yourself, keep it an ordinary single-link mode-`0700` file.
Print one line only when firstmate should wake, print nothing otherwise, and finish before `FM_CHECK_TIMEOUT`.
Bind its current bytes with `bin/fm-check-register.sh <id>` before the watcher may execute it.
Retire a custom check only through `bin/fm-check-unregister.sh <id>`, or `bin/fm-teardown.sh` for a spawned task; never hand-compose an `rm` with `$STATE`/`$ID`.

## Teardown

Tear down a ship task only after landing is confirmed.
A teardown refusal for uncommitted or unlanded work is a stop-and-investigate result, never an obstacle to bypass, and forcing it requires explicit captain discard authority.
After successful teardown, record completion, retain only the configured recent Done history, and re-evaluate queued work whose blockers and time gates have cleared.

A secondmate is persistent and an empty queue is healthy.
Retire one only on an explicit captain or main-firstmate decision, after loading `secondmate-provisioning`.
Its home must contain no work under way, and forced discard still requires explicit captain authority.

## Scout outcome and promotion

A completed scout must leave a self-contained report before its scratch worktree can be discarded.
Read and relay its findings, record the report as the Done artifact, and re-evaluate the queue.
A scout report may recommend implementation but does not authorize it.
Before treating an investigation or visual review as complete, load `captain-hold-lifecycle`; teardown enforces that shared completion gate.

When a scout's deliverable is a visual artifact the captain will iterate on, prefer keeping that scout alive to host its own Lavish loop rather than tearing it down and mediating from firstmate, so the scout keeps its investigation context and the captain iterates in one continuous session.

When implementation is separately authorized, promote the existing scout through `bin/fm-promote.sh` rather than creating a duplicate task.
The promoted worker must inventory scratch state, return to a clean default-branch base, carry over only intended fix changes, create the ship branch, and follow the project's selected delivery path.
It leaves scratch commits and debug edits behind, and turns a reproduced bug into the regression test.
