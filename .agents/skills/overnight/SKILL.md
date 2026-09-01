---
name: overnight
description: >-
  Run an overnight autonomous implementation loop for a dependency-ordered ticket series or explicit ticket list in a named project.
  Use when the captain invokes /overnight, asks for an overnight run, requests an unattended implementation session, or says "work the tickets overnight".
user-invocable: true
metadata:
  internal: true
---

# overnight

Run one serialized implementation loop for the project and ticket series named by the captain's current invocation.
This skill owns only the loop-specific ordering, `/implement` evidence, quota pause and resume, and green-merge advancement rules.
The Firstmate lifecycle remains the owner of intake, authority, briefs, spawning, supervision, delivery, PR state, merging, cleanup, and status handling.

## Inputs and scope

Require one of these ticket inputs together with the project:

- A spine issue with its ordered sub-tickets and dependency edges.
- An explicit list of ticket IDs or URLs.

Read every ticket body and blocking edge through the project's configured tracker before dispatching anything.
Use `gh-axi` for GitHub tickets and PRs, and use the configured tracker owner for another tracker.
Do not infer dependency order from issue numbers, creation dates, or filenames.
If the spine, list, project, or dependency order is missing, ambiguous, contradictory, or inaccessible, stop for the captain rather than guessing.
For an explicit list, topologically order the supplied tickets from their verified blockers and preserve the supplied order among tickets that are independent.
If the list contains a cycle or a dependency that cannot be ordered unambiguously, stop for the captain rather than guessing.

The captain's current invocation scopes this protocol to the named project and supplied tickets.
Do not add tickets or turn this invocation into a standing project-wide delivery policy.

## Existing lifecycle owners

Follow `AGENTS.md` sections 4, 7, and 8 and the referenced script headers for the normal project, authority, isolation, worker, supervision, delivery, PR, merge, cleanup, and status contracts.
Load `harness-adapters` before every spawn or recovery, and use the emitted supervision protocol for every live worker.
Do not restate or bypass those owners, and do not create a second watcher, daemon, or background runner.

This is an invocation-scoped exception, not a default, so do not apply it when the current request does not name the project and ticket set.
The current invocation must be a concrete per-task instruction under the normal authority rules, not a new standing project posture.
If the normal lifecycle cannot establish that authority for the named project and ticket set, stop for the captain.

## Serialized loop

Process the verified ticket order one ticket at a time.
Never dispatch two tickets from one series in parallel.
Do not dispatch the next tracer-bullet ticket until the current PR is confirmed landed through the normal lifecycle, because the next ticket must build on the earlier ticket's landed seam.

For each ticket:

1. Confirm through the normal lifecycle that the ticket is current, its blockers are clear, and the previous ticket is landed.
2. Run the quota gate below immediately before dispatch.
3. Record the branch's starting default-branch commit and pass the complete ticket body, acceptance criteria, project context, review fixed point, and worker additions below to the normal brief owner.
4. Spawn exactly one worker through the normal owner with harness `codex`, model `gpt-5.6-luna`, and effort `max`.
5. Keep the worker under the emitted supervision protocol and apply the evidence and delivery gates below.
6. After the PR is confirmed landed, re-run the quota gate before dispatching the next ticket.

### Worker additions

Add these ticket-specific requirements to the ordinary ship instructions:

- Open and read `~/.agents/skills/implement/SKILL.md` in full before changing code.
- Invoke the `/implement` skill after reading it, using Codex's native `$implement` spelling, rather than treating the file read as a substitute for using the skill.
- The file is user-invoked and carries `disable-model-invocation: true`, so the worker must not assume that the runtime auto-loaded it.
- Run the built-in `/code-review` skill against the recorded starting default-branch commit, use the current ticket as its specification source, and resolve its findings before pushing.
- Use Codex's native `$code-review` spelling when invoking that built-in skill.
- Do not substitute another model, effort, or runtime if the requested profile cannot be launched.

### Verifying `/implement`

The `/implement` read and invocation are acceptance evidence, not claims to trust from the brief.
Require the worker to append a material status receipt after the full read and before pushing, naming the literal path, its line count, its SHA-256 digest, and the implementation-skill directives it applied.
The directives named in the receipt must include the skill's testing and review steps.

Before accepting the result, inspect the worker's recorded output with `bin/fm-peek.sh <task-id>` for the full-file read and native `$implement` invocation.
Read the durable receipt and independently recompute the line count and SHA-256 digest of `~/.agents/skills/implement/SKILL.md` with the locally available hashing tool.
Require exact receipt matches and separate evidence that the built-in `code-review` completed before the direct PR was pushed.
If the pane output, receipt, digest, invocation, or review evidence is missing or contradictory, do not accept or advance the ticket.
Send a durable correction through the normal steering path and require a fresh read and receipt, or stop the loop with the ticket unresolved if proof cannot be produced.

## Quota gate

Immediately before every new dispatch, run `quota-axi --json` and inspect that report rather than a cached conversational value.
For both the `claude` and `codex` providers, locate the entry in `windows[]` whose `id` is `five_hour`.
Use that entry's `percentRemaining` for the gate and its `resetsAt` for a pause.
Dispatch only when both five-hour `percentRemaining` values are strictly greater than `18`.
Treat `18.0` or lower as closed even when the other provider has more headroom.

Do not use quota-axi's default TOON percentage for this decision.
That display reports effective bounded availability, which may be limited by a weekly or another account window and is not the five-hour `percentRemaining` required here.
Do not replace a missing, stale, malformed, or unreadable five-hour value with an effective percentage, a model percentage, a cached value, or an assumption that the provider is healthy.
If either required provider or window cannot be read as current JSON, stop dispatching and surface the concrete quota evidence problem.

When either five-hour window is at or below `18`:

1. Stop dispatching new tickets.
2. Let any already in-flight ticket finish its current implementation, review, and delivery attempt.
3. Record `resetsAt` for every currently closed five-hour window and wait for the earliest of those reported reset times.
4. Re-run `quota-axi --json` at that reset, and if any window is still closed, wait for its newly reported `resetsAt` and repeat.
5. Resume dispatching only after one fresh JSON report shows both five-hour values strictly greater than `18`.

If a closed window has no valid `resetsAt`, stop with a concrete quota blocker rather than guessing a delay.
A quota pause never authorizes interrupting, abandoning, or parallelizing the current ticket.
Keep the normal supervision cycle live while waiting.

## Delivery and merge gate

For this protocol's named tickets, resolve delivery as `direct-PR` with `yolo on`; that recorded posture authorizes the later merge step, while the built-in `code-review` skill is the only review and the `no-mistakes` pipeline is not used.
Complete the review before the worker pushes, then use the normal PR-check and merge owners for the current PR head.
Never dispatch a later ticket while the current PR is open or its gate is unknown.
Pending, failed, cancelled, missing, or unreadable checks are not green, and a red PR is never merged.
When the gate is green, invoke the normal merge owner for the named ticket without waiting for another captain message, and stop if that owner refuses the recorded authority.

If the target repository has no CI configured at all, establish that fact separately from an empty or unavailable check result.
Run the project's own documented test or validation suite locally on the worker's branch, capture the exact passing evidence in the task record, and use that local result as the merge gate.
For GitHub, use the current `gh-axi pr checks` interface and its current help rather than a cached status.
"No checks" and "checks passed" are different facts, and an empty check list without proof of absent CI never counts as green.
If no documented local suite exists for a repository with no CI, stop with a concrete blocker rather than treating the absence of checks as approval.

After the normal merge owner confirms that the PR landed, let the normal lifecycle complete cleanup before re-evaluating the queue.
If the merge result cannot be proved, keep the current ticket active and stop the loop rather than advancing on an assumption.

## Pause and stop conditions

Pause the loop and preserve the current ticket whenever a worker raises a decision belonging to the captain.
Follow `AGENTS.md` section 7 and the owning decision procedure for that decision, and do not guess at product, destructive, irreversible, security-sensitive, or merge choices.
The overnight instruction never expands approval authority because the captain is unavailable.

Stop successfully when every supplied ticket has a confirmed landed PR and the normal lifecycle has completed cleanup.
Stop unresolved when a ticket fails in a way the normal lifecycle cannot repair, required quota evidence cannot be established, required `/implement` or review evidence cannot be verified, a green merge cannot be proved, or a captain decision is required.
