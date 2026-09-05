---
name: task-steering
description: >-
  Agent-only mechanics for handing work to a live crewmate or secondmate and steering it afterwards.
  Load before sending a worker text, answering an open decision or blocker, or driving a worker's interrupt, exit, or relaunch.
---

# Task steering

`AGENTS.md` section 7 owns intake, delivery mode, and merge authority.
This skill owns only what happens between a completed spawn and a finished worker.

## Dispatch handoff

The spawn itself moves the work item to In flight when the configured tasks-axi backlog gate applies, and refuses rather than dispatching work this home has no item for, so recording the dispatch is never a separate step to remember.
A manual-backend home retains the hand-editing contract in [`docs/configuration.md`](../../../docs/configuration.md).
A persistent secondmate is recorded in the secondmate registry and runtime state, never as a backlog work item.

## Steering with text

Steer a worker with ordinary text through `fm-send`, which refuses rather than delivering silently.
The message becomes a durable record in the task's steering inbox, multi-line text is legal for local and remote workers alike, and the worker's terminal receives only a constant doorbell line.
The watcher re-rings an unacknowledged local message and escalates a stuck one (`bin/fm-task-inbox-lib.sh`; `bin/fm-send.sh` owns the typed-plane carve-outs).

A remote secondmate steer rides the same durable-inbox model through the remote transport.
After an unconfirmed delivery, only the exact `FM_PENDING_REPLY_EXISTING_CORR=<id>` resend command printed by `fm-send` is safe, because it preserves the request body for remote enqueue deduplication (`bin/fm-send.sh` header).
For the parent-owned correlation, recovery, and escalation contract on marked secondmate requests, see `bin/fm-pending-reply-lib.sh`.

When a steer answers an open keyed decision or blocker, pass `fm-send`'s `--resolve-key` so the answer itself closes that decision record at answer time, identically for local and remote workers (contract: `bin/fm-send.sh` header).

## Lifecycle control is a separate plane

`fm-send` is the data plane for text the worker should read.
Never use its key or text paths for interrupt, exit, or other lifecycle control, because routing-marked lifecycle text becomes chat the worker reasons about instead of executing.
Drive a worker's lifecycle through `bin/fm-control.sh <task-id> interrupt|exit|relaunch`, which owns the per-runtime mechanics, verifies each action, and never tears down or discards anything ([`docs/agent-control.md`](../../../docs/agent-control.md)).

## Secondmate replies

A secondmate's routed reply returns through status or a document pointer.
Never read the secondmate's chat to find it.
